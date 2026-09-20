#include "GPU3D_Diagnostic.h"
#include <cassert>
#include <csignal>
#include <fstream>
#include <iterator>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int main()
{
    char path[] = "/tmp/nds-black-capture-limit-XXXXXX";
    int fd = mkstemp(path); assert(fd >= 0); close(fd);
    std::string large;
    for (int i = 0; i < 8192; ++i)
        large += "polygon=123 vertex=1 color=511,511,511\n";
    for (const rlim_t limit : {rlim_t(65536), rlim_t(4096)})
    {
        // Control reproduces the process-killing failure at the real limit.
        pid_t child = fork(); assert(child >= 0);
        if (child == 0)
        {
            rlimit bound {limit, limit}; assert(setrlimit(RLIMIT_FSIZE, &bound) == 0);
            std::signal(SIGXFSZ, SIG_DFL);
            FILE* f = fopen(path, "wb"); assert(f);
            fwrite(large.data(), 1, large.size(), f); fclose(f); _exit(2);
        }
        int status = 0; assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGXFSZ);
        child = fork(); assert(child >= 0);
        if (child == 0)
        {
            rlimit bound {limit, limit}; assert(setrlimit(RLIMIT_FSIZE, &bound) == 0);
            std::signal(SIGXFSZ, SIG_DFL);
            _exit(melonDS::WriteBounded3DDiagnostic(path, large) ? 0 : 3);
        }
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        struct stat st {}; assert(stat(path, &st) == 0);
        assert(st.st_size <= static_cast<off_t>(limit));
        std::ifstream f(path); std::string text((std::istreambuf_iterator<char>(f)), {});
        const std::string marker = "TRUNCATED_BY_DIAGNOSTIC_LIMIT\n";
        assert(text.size() >= marker.size());
        assert(text.compare(text.size() - marker.size(), marker.size(), marker) == 0);
    }
    unlink(path);
    puts("BLACK_INPUT_CAPTURE_LIMIT_PASS limits=65536,4096 negative_control=SIGXFSZ");
}
