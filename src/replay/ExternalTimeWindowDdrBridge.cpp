#include "replay/ExternalTimeWindowDdrBridge.h"

#include <exception>
#include <utility>

namespace nds4mister {
namespace {

class ClosureRejected final {};

void setError(std::string& error, const char* message) noexcept {
    try {
        error = message;
    } catch (...) {
        // Error reporting is secondary. The producer has already latched the
        // callback fault and prevents a retry of the irreversible closure.
    }
}

void reject(std::string& error, const char* message) {
    setError(error, message);
    throw ClosureRejected{};
}

} // namespace

ExternalTimeWindowDdrPublishResult publishExternalTimeWindowDdr(
    ExternalTimeWindowDdrProducer& producer,
    std::size_t queuedTransitionsBeforeClosure,
    const ExternalTimeWindowDdrClosure& close,
    ExternalTimeWindowDdrReceipt& receipt,
    std::string& error) noexcept {
    error.clear();

    try {
        return producer.publish(
            [&]() -> ExternalTimeWindowDdrGroup {
                // This executes only after the producer has proven its
                // session, capacity, and sequence state. It deliberately
                // precedes the irreversible model closure.
                if (queuedTransitionsBeforeClosure != 0) {
                    setError(
                        error,
                        "external IRQ transition queue was not empty before "
                        "time-window closure");
                    throw ClosureRejected{};
                }

                ExternalTimeWindowDdrClosureOutput output;
                std::string closureError;
                if (!close(output, closureError)) {
                    try {
                        error = closureError.empty()
                            ? "external time-window closure failed"
                            : std::move(closureError);
                    } catch (...) {
                        // This allocation failure still occurs inside the
                        // producer callback and therefore poisons the epoch.
                    }
                    throw ClosureRejected{};
                }

                ExternalTimeWindowDdrGroup group;
                group.processedThroughInclusive =
                    output.window.processedThrough;
                group.runSafeThroughInclusive =
                    output.window.runSafeThrough;
                group.lastEventSequence =
                    output.window.lastEventSequence;

                // Keep every potentially throwing allocation and conversion
                // inside producer.publish()'s callback. Its catch-all marks
                // the epoch non-retryable if closure has already changed the
                // emulator model.
                group.events.reserve(output.transitions.size());
                for (const auto& transition : output.transitions) {
                    group.events.push_back({
                        transition.sequence,
                        transition.timestamp,
                        transition.arm9,
                        transition.set,
                        transition.mask,
                    });
                }
                return group;
            },
            receipt);
    } catch (const ClosureRejected&) {
        if (error.empty())
            setError(error, "external time-window closure was rejected");
    } catch (const std::exception& exception) {
        setError(error, exception.what());
    } catch (...) {
        setError(error, "external time-window closure threw an exception");
    }

    return ExternalTimeWindowDdrPublishResult::Fault;
}

ExternalTimeWindowDdrPublishResult publishExternalBlockingMMIODdr(
    ExternalTimeWindowDdrProducer& producer,
    std::size_t queuedTransitionsBeforeClosure,
    const ExternalTimeWindowDdrBarrierIdentity& expected,
    const ExternalBlockingMMIODdrClosure& close,
    ExternalTimeWindowDdrReceipt& receipt,
    ExternalBlockingMMIODdrReadResponse& readResponse,
    std::string& error) noexcept {
    receipt = {};
    readResponse = {};
    error.clear();
    std::uint32_t pendingReadData = 0;

    try {
        const auto result = producer.publishBarrierReplacement(
            expected,
            [&]() -> ExternalTimeWindowDdrBarrierReplacement {
                // This callback is reached only after the BRRP producer has
                // reserved the complete transport slot and exact event
                // capacity. Check the backend queue at that boundary so no
                // older unnamed IRQ suffix can be relabelled by this barrier.
                if (queuedTransitionsBeforeClosure != 0) {
                    reject(
                        error,
                        "external IRQ transition queue was not empty before "
                        "blocking-MMIO closure");
                }

                ExternalBlockingMMIOCompletion completion;
                std::string closureError;
                if (!close(completion, closureError)) {
                    try {
                        error = closureError.empty()
                            ? "external blocking-MMIO closure failed"
                            : std::move(closureError);
                    } catch (...) {
                        // Producer callback catch-all still poisons this
                        // irreversible model transaction.
                    }
                    throw ClosureRejected{};
                }

                const auto& window = completion.window;
                if (window.epoch != expected.epoch)
                    reject(error, "blocking-MMIO replacement epoch mismatch");
                if (window.grantSequence !=
                    expected.activeGrantGroupSequence + 1u) {
                    reject(
                        error,
                        "blocking-MMIO replacement grant sequence mismatch");
                }
                if (window.replacesGrantSequence !=
                    expected.activeGrantGroupSequence) {
                    reject(
                        error,
                        "blocking-MMIO replaced-grant sequence mismatch");
                }
                if (window.verifiedProducerFence !=
                    expected.verifiedProducerFence) {
                    reject(
                        error,
                        "blocking-MMIO verified producer fence mismatch");
                }
                if (!window.replacesBlockingMMIO)
                    reject(error, "blocking-MMIO replacement flag missing");
                if (window.barrierSourceSequence != expected.sourceSequence)
                    reject(error, "blocking-MMIO barrier source mismatch");
                if (window.barrierSequence != expected.barrierSequence)
                    reject(error, "blocking-MMIO barrier sequence mismatch");
                if (window.barrierTimestamp != expected.barrierTimestamp)
                    reject(error, "blocking-MMIO barrier timestamp mismatch");
                if (window.processedThrough != expected.barrierTimestamp) {
                    reject(
                        error,
                        "blocking-MMIO replacement processed frontier was "
                        "not the admitted barrier");
                }
                if (completion.transitions.size() > expected.eventCount) {
                    reject(
                        error,
                        "blocking-MMIO replacement exceeded reserved event "
                        "capacity");
                }

                ExternalTimeWindowDdrBarrierReplacement replacement;
                replacement.identity = expected;
                replacement.group.processedThroughInclusive =
                    window.processedThrough;
                replacement.group.runSafeThroughInclusive =
                    window.runSafeThrough;
                replacement.group.lastEventSequence =
                    window.lastEventSequence;
                replacement.group.events.reserve(
                    completion.transitions.size());
                for (const auto& transition : completion.transitions) {
                    replacement.group.events.push_back({
                        transition.sequence,
                        transition.timestamp,
                        transition.arm9,
                        transition.set,
                        transition.mask,
                    });
                }
                pendingReadData = completion.readData;
                return replacement;
            },
            receipt);

        if (result == ExternalTimeWindowDdrPublishResult::Published) {
            readResponse = {
                expected.epoch,
                expected.sourceSequence,
                expected.barrierSequence,
                pendingReadData,
                true,
            };
        } else if (result == ExternalTimeWindowDdrPublishResult::Fault &&
                   error.empty()) {
            setError(error, "external blocking-MMIO DDR publication failed");
        }
        return result;
    } catch (const ClosureRejected&) {
        if (error.empty()) {
            setError(
                error,
                "external blocking-MMIO closure was rejected");
        }
    } catch (const std::exception& exception) {
        setError(error, exception.what());
    } catch (...) {
        setError(error, "external blocking-MMIO closure threw an exception");
    }

    return ExternalTimeWindowDdrPublishResult::Fault;
}

} // namespace nds4mister
