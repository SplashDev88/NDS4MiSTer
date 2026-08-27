#include "bench/Benchmark.h"
#include "bench/Options.h"
#ifdef NDS4MISTER_USE_MELONDS
#include "melonds/MelonDsBackend.h"
#endif
#include "core/NullEmulatorBackend.h"

#include <iostream>
#include <memory>

int main(int argc, char** argv)
{
    nds4mister::Options options;
    std::string error;

    if (!nds4mister::parse_options(argc, argv, options, error)) {
        if (!error.empty()) {
            std::cerr << "error: " << error << "\n";
            nds4mister::print_usage(argv[0]);
            return 2;
        }
        return 0;
    }

    std::unique_ptr<nds4mister::IEmulatorBackend> backend;
#ifdef NDS4MISTER_USE_MELONDS
    backend = std::make_unique<nds4mister::MelonDsBackend>();
#else
    backend = std::make_unique<nds4mister::NullEmulatorBackend>();
#endif

    nds4mister::BenchmarkResult result;
    if (!nds4mister::run_benchmark(*backend, options, result, error)) {
        std::cerr << "error: " << error << "\n";
        return 1;
    }

    nds4mister::print_report(*backend, options, result);
    if (!nds4mister::write_json_report(*backend, options, result, error)) {
        std::cerr << "error: " << error << "\n";
        return 1;
    }

    return 0;
}
