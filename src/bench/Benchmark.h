#pragma once

#include "bench/Options.h"
#include "core/EmulatorBackend.h"

namespace nds4mister {

struct BenchmarkResult {
    double total_seconds = 0.0;
    double cpu_seconds = 0.0;
    double gpu_seconds = 0.0;
    double audio_seconds = 0.0;
    double other_seconds = 0.0;
};

bool run_benchmark(IEmulatorBackend& backend,
                   const Options& options,
                   BenchmarkResult& result,
                   std::string& error);

void print_report(const IEmulatorBackend& backend,
                  const Options& options,
                  const BenchmarkResult& result);

bool write_json_report(const IEmulatorBackend& backend,
                       const Options& options,
                       const BenchmarkResult& result,
                       std::string& error);

} // namespace nds4mister
