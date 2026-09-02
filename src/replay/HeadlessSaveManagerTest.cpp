#include "melonds/HeadlessSaveManager.h"
#include "melonds/HeadlessSaveDurability.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {

using nds4mister::HeadlessSaveManager;
using namespace std::chrono_literals;

class TemporaryDirectory final {
public:
    TemporaryDirectory()
    {
        std::array<char, 64> name{};
        const std::string pattern = "/tmp/nds4mister-save-test.XXXXXX";
        std::copy(pattern.begin(), pattern.end(), name.begin());
        char* created = mkdtemp(name.data());
        if (!created) throw std::runtime_error("mkdtemp failed");
        path_ = created;
    }

    ~TemporaryDirectory()
    {
        std::error_code ignored;
        std::filesystem::remove_all(path_, ignored);
    }

    const std::filesystem::path& path() const noexcept { return path_; }

private:
    std::filesystem::path path_;
};

[[noreturn]] void fail(const char* expression, int line,
    const std::string& detail = {})
{
    std::string message = "line " + std::to_string(line) + ": " + expression;
    if (!detail.empty()) message += " (" + detail + ")";
    throw std::runtime_error(message);
}

#define CHECK(expression) \
    do { if (!(expression)) fail(#expression, __LINE__); } while (false)
#define CHECK_DETAIL(expression, detail) \
    do { if (!(expression)) fail(#expression, __LINE__, (detail)); } while (false)

std::vector<std::uint8_t> readFile(const std::filesystem::path& path)
{
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("cannot open test output");
    const auto length = input.tellg();
    if (length < 0) throw std::runtime_error("cannot size test output");
    std::vector<std::uint8_t> result(static_cast<std::size_t>(length));
    input.seekg(0);
    if (!result.empty() && !input.read(
            reinterpret_cast<char*>(result.data()), length))
        throw std::runtime_error("cannot read test output");
    return result;
}

void writeFile(const std::filesystem::path& path,
    const std::vector<std::uint8_t>& data)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output || (!data.empty() && !output.write(
            reinterpret_cast<const char*>(data.data()), data.size())))
        throw std::runtime_error("cannot write test fixture");
}

void submit(HeadlessSaveManager& manager,
    const std::vector<std::uint8_t>& data, std::uint32_t offset,
    std::uint32_t length)
{
    auto* callback = manager.callback();
    CHECK(callback != nullptr);
    CHECK(callback->write != nullptr);
    callback->write(callback->opaque, data.data(),
        static_cast<std::uint32_t>(data.size()), offset, length);
}

void testContentIdentity()
{
    CHECK(HeadlessSaveManager::contentId(nullptr, 0) ==
        "e3b0c44298fc1c149afbf4c8996fb924"
        "27ae41e4649b934ca495991b7852b855");
    constexpr std::array<std::uint8_t, 3> abc{{'a', 'b', 'c'}};
    CHECK(HeadlessSaveManager::contentId(abc.data(), abc.size()) ==
        "ba7816bf8f01cfea414140de5dae2223"
        "b00361a396177a9cb410ff61f20015ad");
    CHECK(HeadlessSaveManager::contentId(nullptr, 1).empty());
}

void testDirectorySyncPolicy()
{
    CHECK(nds4mister::headlessSaveDirectorySyncUnsupported(EINVAL));
    CHECK(nds4mister::headlessSaveDirectorySyncUnsupported(EROFS));
#ifdef ENOTSUP
    CHECK(nds4mister::headlessSaveDirectorySyncUnsupported(ENOTSUP));
#endif
#ifdef EOPNOTSUPP
    CHECK(nds4mister::headlessSaveDirectorySyncUnsupported(EOPNOTSUPP));
#endif
    CHECK(!nds4mister::headlessSaveDirectorySyncUnsupported(EIO));
}

void testPersistenceLifecycle(const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 5> identityBytes{{4, 8, 15, 16, 23}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);

    // The per-ROM advisory lock prevents two independent writers from
    // silently replacing one another's atomic commits.
    std::string duplicateError;
    auto duplicate = HeadlessSaveManager::create(
        root.string(), identity, duplicateError, 5ms, 25ms);
    CHECK(duplicate == nullptr);
    CHECK(!duplicateError.empty());

    std::unique_ptr<std::uint8_t[]> loaded;
    std::uint32_t loadedLength = 99;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(!loaded);
    CHECK(loadedLength == 0);

    std::vector<std::uint8_t> live(8192, 0xff);
    CHECK_DETAIL(manager->initialize(
        live.data(), live.size(), loadedLength, error), error);

    for (std::size_t index = 100; index < 132; ++index)
        live[index] = static_cast<std::uint8_t>(index);
    submit(*manager, live, 100, 32);

    // The debounce worker must eventually persist without blocking the
    // emulation callback on filesystem I/O.
    const auto deadline = std::chrono::steady_clock::now() + 2s;
    while (manager->stats().commits == 0 &&
           std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(2ms);
    CHECK(manager->stats().commits == 1);
    CHECK(readFile(manager->savePathForTest()) == live);

    for (std::size_t index = 200; index < 208; ++index)
        live[index] ^= 0x5a;
    submit(*manager, live, 200, 8);
    CHECK_DETAIL(manager->flush(error), error);
    CHECK(readFile(manager->savePathForTest()) == live);
    const auto firstStats = manager->stats();
    CHECK(firstStats.callbacks == 2);
    CHECK(firstStats.callbackBytes == 40);
    CHECK(firstStats.commits == 2);
    CHECK(firstStats.failures == 0);
    CHECK(!firstStats.dirty);
    CHECK_DETAIL(manager->shutdown(error), error);
    manager.reset();

    // A new session must recover the exact raw save and may modify a range
    // that wraps at the end of the cartridge save address space.
    manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == live.size());
    CHECK(std::equal(live.begin(), live.end(), loaded.get()));
    CHECK_DETAIL(manager->initialize(
        loaded.get(), loadedLength, loadedLength, error), error);

    live[live.size() - 2] = 0x11;
    live[live.size() - 1] = 0x22;
    live[0] = 0x33;
    live[1] = 0x44;
    submit(*manager, live, live.size() - 2, 4);
    CHECK_DETAIL(manager->flush(error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
    CHECK(readFile(manager->savePathForTest()) == live);
}

void testShortReplacementCallback(const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 2> identityBytes{{7, 7}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    std::vector<std::uint8_t> full(64, 0xff);
    CHECK_DETAIL(manager->initialize(full.data(), full.size(), 0, error), error);

    // melonDS SetSaveMemory supplies the replacement buffer's length rather
    // than the cart's complete SRAM length.  Preserve untouched tail bytes.
    std::vector<std::uint8_t> replacement(8, 0xa5);
    auto* callback = manager->callback();
    callback->write(callback->opaque, replacement.data(), replacement.size(),
        0, replacement.size());
    std::copy(replacement.begin(), replacement.end(), full.begin());
    CHECK_DETAIL(manager->flush(error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
    CHECK(readFile(manager->savePathForTest()) == full);
}

void testLateSaveAllocation(const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 3> identityBytes{{9, 9, 7}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    CHECK_DETAIL(manager->initialize(nullptr, 0, 0, error), error);

    std::vector<std::uint8_t> allocated(512, 0xff);
    allocated[17] = 0x42;
    submit(*manager, allocated, 17, 1);
    CHECK_DETAIL(manager->flush(error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
    CHECK(manager->stats().saveBytes == allocated.size());
    CHECK(readFile(manager->savePathForTest()) == allocated);
}

void testFullChipBoundaryCallback(const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 4> identityBytes{{6, 5, 5, 3}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);

    // This is the exact Platform::WriteNDSSave shape produced when melonDS
    // reports a write covering a complete 64 KiB EEPROM/FRAM device:
    // SPIRelease masks 0x10000 by SRAMLength-1 and passes zero as the changed
    // range length.  The complete live buffer is authoritative and must still
    // replace the persisted save.
    std::vector<std::uint8_t> live(64u * 1024u, 0xff);
    CHECK_DETAIL(manager->initialize(
        live.data(), live.size(), 0, error), error);
    std::fill(live.begin(), live.end(), 0x00);
    auto* callback = manager->callback();
    callback->write(callback->opaque, nullptr, 0, 0, 0);
    callback->write(callback->opaque, live.data(), live.size(), 0x3141, 0);
    CHECK_DETAIL(manager->flush(error), error);
    CHECK(readFile(manager->savePathForTest()) == live);
    const auto stats = manager->stats();
    CHECK(stats.callbacks == 1);
    CHECK(stats.callbackBytes == live.size());
    CHECK(stats.commits == 1);
    CHECK(stats.failures == 0);
    CHECK_DETAIL(manager->shutdown(error), error);
    manager.reset();

    // Verify the corrected boundary survives a complete unload/reload cycle.
    manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    std::unique_ptr<std::uint8_t[]> loaded;
    std::uint32_t loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == live.size());
    CHECK(std::equal(live.begin(), live.end(), loaded.get()));
    CHECK_DETAIL(manager->initialize(
        loaded.get(), loadedLength, loadedLength, error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
}

void testStandardSaveSizeRanges(const std::filesystem::path& root)
{
    constexpr std::array<std::uint32_t, 5> sizes{{
        512u, 8u * 1024u, 64u * 1024u, 256u * 1024u, 512u * 1024u,
    }};
    for (const auto size : sizes) {
        std::array<std::uint8_t, 8> identityBytes{{
            0x53, 0x41, 0x56, 0x45,
            static_cast<std::uint8_t>(size),
            static_cast<std::uint8_t>(size >> 8),
            static_cast<std::uint8_t>(size >> 16),
            static_cast<std::uint8_t>(size >> 24),
        }};
        const auto identity = HeadlessSaveManager::contentId(
            identityBytes.data(), identityBytes.size());
        std::string error;
        auto manager = HeadlessSaveManager::create(
            root.string(), identity, error, 5ms, 25ms);
        CHECK_DETAIL(manager != nullptr, error);
        std::vector<std::uint8_t> live(size, 0xff);
        CHECK_DETAIL(manager->initialize(
            live.data(), size, 0, error), error);

        // Byte, word-sized, end-of-chip, and wrapping page updates must all
        // retain every untouched erased byte.
        live[3] = 0x12;
        submit(*manager, live, 3, 1);
        for (std::uint32_t index = 17; index < 21; ++index)
            live[index] = static_cast<std::uint8_t>(index ^ 0xa5u);
        submit(*manager, live, 17, 4);
        live[size - 1] = 0x5a;
        submit(*manager, live, size - 1, 1);
        live[size - 2] = 0x81;
        live[size - 1] = 0x82;
        live[0] = 0x83;
        live[1] = 0x84;
        submit(*manager, live, size - 2, 4);

        CHECK_DETAIL(manager->flush(error), error);
        CHECK(readFile(manager->savePathForTest()) == live);
        CHECK_DETAIL(manager->shutdown(error), error);
    }
}

void testStaleTemporaryAndLengthMismatch(
    const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 3> identityBytes{{1, 2, 9}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::filesystem::create_directories(root);
    const auto base = std::string("sha256-") + identity + ".sav";
    const auto stale = root / ("." + base + ".tmp.abandoned");
    writeFile(stale, {0xde, 0xad});

    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    CHECK(!std::filesystem::exists(stale));
    writeFile(root / base, {1, 2, 3, 4});

    std::unique_ptr<std::uint8_t[]> loaded;
    std::uint32_t loadedLength = 0;
    CHECK_DETAIL(manager->loadExisting(loaded, loadedLength, error), error);
    CHECK(loadedLength == 4);
    std::vector<std::uint8_t> expected(8, 0xff);
    CHECK(!manager->initialize(
        expected.data(), expected.size(), loadedLength, error));
    CHECK(!error.empty());
}

void testInvalidCallbackFailsClosed(const std::filesystem::path& root)
{
    const std::array<std::uint8_t, 2> identityBytes{{5, 8}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    std::vector<std::uint8_t> live(16, 0xff);
    CHECK_DETAIL(manager->initialize(live.data(), live.size(), 0, error), error);
    auto* callback = manager->callback();
    callback->write(callback->opaque, live.data(), live.size() + 1, 0, 1);
    CHECK(!manager->flush(error));
    CHECK(!error.empty());
    CHECK(!manager->shutdown(error));
    CHECK(manager->stats().failures == 1);
}

void testAtomicFailureRecovery(const std::filesystem::path& parent)
{
    const auto root = parent / "failure-root";
    const auto movedRoot = parent / "failure-root-moved";
    const std::array<std::uint8_t, 4> identityBytes{{3, 1, 4, 1}};
    const auto identity = HeadlessSaveManager::contentId(
        identityBytes.data(), identityBytes.size());
    std::string error;
    auto manager = HeadlessSaveManager::create(
        root.string(), identity, error, 5ms, 25ms);
    CHECK_DETAIL(manager != nullptr, error);
    std::vector<std::uint8_t> live(256, 0x21);
    CHECK_DETAIL(manager->initialize(live.data(), live.size(), 0, error), error);
    submit(*manager, live, 0, live.size());
    CHECK_DETAIL(manager->flush(error), error);
    const auto filename = std::filesystem::path(
        manager->savePathForTest()).filename();
    CHECK(readFile(root / filename) == live);

    // Make future temporary-file creation fail while retaining the original
    // committed directory under a new name.  The prior .sav must stay intact.
    std::filesystem::rename(root, movedRoot);
    writeFile(root, {0});
    live[17] ^= 0xff;
    submit(*manager, live, 17, 1);
    error.clear();
    CHECK(!manager->flush(error));
    CHECK(!error.empty());
    CHECK(readFile(movedRoot / filename) != live);
    CHECK(manager->stats().failures >= 1);
    CHECK(manager->stats().dirty);

    // Once storage returns, the same dirty generation remains available and
    // can be committed without asking the emulator to repeat its callback.
    std::filesystem::remove(root);
    std::filesystem::rename(movedRoot, root);
    error.clear();
    CHECK_DETAIL(manager->flush(error), error);
    CHECK_DETAIL(manager->shutdown(error), error);
    CHECK(readFile(root / filename) == live);
}

} // namespace

int main() try
{
    testContentIdentity();
    testDirectorySyncPolicy();
    TemporaryDirectory temporary;
    testPersistenceLifecycle(temporary.path() / "restart");
    testShortReplacementCallback(temporary.path() / "replacement");
    testLateSaveAllocation(temporary.path() / "late-allocation");
    testFullChipBoundaryCallback(temporary.path() / "full-chip-boundary");
    testStandardSaveSizeRanges(temporary.path() / "standard-sizes");
    testStaleTemporaryAndLengthMismatch(temporary.path() / "mismatch");
    testInvalidCallbackFailsClosed(temporary.path() / "invalid-callback");
    testAtomicFailureRecovery(temporary.path());
    std::cout << "NDS4MISTER_HEADLESS_SAVE_TEST_V1 status=pass\n";
    return 0;
} catch (const std::exception& exception) {
    std::cerr << "NDS4MISTER_HEADLESS_SAVE_TEST_V1 status=fail error=\""
              << exception.what() << "\"\n";
    return 1;
}
