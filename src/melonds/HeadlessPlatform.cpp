#include "Platform.h"
#include "melonds/HeadlessSaveCallback.h"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

#if defined(__linux__)
#include <climits>
#include <linux/futex.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace melonDS::Platform {

struct FileHandle {
    std::FILE* file = nullptr;
};

struct Thread {
    std::thread thread;
};

struct Semaphore {
#if defined(__linux__)
    // NDS4MiSTer's headless renderer uses these fences between one producer
    // and one consumer. Keep the uncontended hand-off entirely in userspace;
    // the kernel is entered only when the consumer really has to sleep.
    // This mirrors DreamSTer's atomic SPSC synchronization without changing
    // melonDS's public semaphore contract or its desktop frontends.
    std::atomic<int> count {0};
    std::atomic<unsigned> waiters {0};
#else
    std::mutex mutex;
    std::condition_variable cv;
    int count = 0;
#endif
};

struct Mutex {
    std::mutex mutex;
};

struct DynamicLibrary {
    void* handle = nullptr;
};

namespace {

const char* fopen_mode(FileMode mode)
{
    const bool read = (mode & Read) != 0;
    const bool write = (mode & Write) != 0;
    const bool append = (mode & Append) != 0;
    const bool preserve = (mode & Preserve) != 0;
    const bool text = (mode & Text) != 0;

    if (append)
        return text ? "a+" : "a+b";
    if (read && write)
        return text ? (preserve ? "r+" : "w+") : (preserve ? "r+b" : "w+b");
    if (write)
        return text ? (preserve ? "a" : "w") : (preserve ? "ab" : "wb");
    return text ? "r" : "rb";
}

bool mode_no_create(FileMode mode)
{
    return (mode & NoCreate) != 0;
}

#if defined(__linux__)
static_assert(
    std::atomic<int>::is_always_lock_free,
    "the Linux headless semaphore requires lock-free 32-bit atomics");

int futex_wait(
    std::atomic<int>& value, int expected, const timespec* timeout = nullptr)
{
    return static_cast<int>(syscall(
        SYS_futex, reinterpret_cast<int*>(&value), FUTEX_WAIT_PRIVATE,
        expected, timeout, nullptr, 0));
}

void futex_wake_all(std::atomic<int>& value)
{
    (void)syscall(
        SYS_futex, reinterpret_cast<int*>(&value), FUTEX_WAKE_PRIVATE,
        INT_MAX, nullptr, nullptr, 0);
}

bool semaphore_try_consume(std::atomic<int>& count)
{
    auto available = count.load(std::memory_order_acquire);
    while (available > 0) {
        if (count.compare_exchange_weak(
                available, available - 1,
                std::memory_order_acquire,
                std::memory_order_relaxed))
            return true;
    }
    return false;
}
#endif

} // namespace

void SignalStop(StopReason, void*) {}

std::string GetLocalFilePath(const std::string& filename)
{
    return filename;
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if (mode_no_create(mode) && !std::filesystem::exists(path))
        return nullptr;

    std::FILE* file = std::fopen(path.c_str(), fopen_mode(mode));
    if (!file)
        return nullptr;

    return new FileHandle {file};
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(path, mode);
}

bool FileExists(const std::string& name)
{
    return std::filesystem::exists(name);
}

bool LocalFileExists(const std::string& name)
{
    return FileExists(name);
}

bool CheckFileWritable(const std::string& filepath)
{
    FileHandle* file = OpenFile(filepath, static_cast<FileMode>(FileMode::Write | FileMode::Preserve));
    if (!file)
        return false;
    return CloseFile(file);
}

bool CheckLocalFileWritable(const std::string& filepath)
{
    return CheckFileWritable(filepath);
}

bool CloseFile(FileHandle* file)
{
    if (!file)
        return false;
    const int result = std::fclose(file->file);
    delete file;
    return result == 0;
}

bool IsEndOfFile(FileHandle* file)
{
    return !file || std::feof(file->file) != 0;
}

bool FileReadLine(char* str, int count, FileHandle* file)
{
    return file && std::fgets(str, count, file->file) != nullptr;
}

u64 FilePosition(FileHandle* file)
{
    if (!file)
        return 0;
    const auto pos = ftello(file->file);
    return pos < 0 ? 0 : static_cast<u64>(pos);
}

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    if (!file)
        return false;

    int whence = SEEK_SET;
    if (origin == FileSeekOrigin::Current)
        whence = SEEK_CUR;
    else if (origin == FileSeekOrigin::End)
        whence = SEEK_END;

    return fseeko(file->file, offset, whence) == 0;
}

void FileRewind(FileHandle* file)
{
    if (file)
        std::rewind(file->file);
}

u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
{
    if (!file)
        return 0;
    return std::fread(data, static_cast<std::size_t>(size), static_cast<std::size_t>(count), file->file);
}

bool FileFlush(FileHandle* file)
{
    return file && std::fflush(file->file) == 0;
}

u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
{
    if (!file)
        return 0;
    return std::fwrite(data, static_cast<std::size_t>(size), static_cast<std::size_t>(count), file->file);
}

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    if (!file)
        return 0;

    va_list args;
    va_start(args, fmt);
    const int written = std::vfprintf(file->file, fmt, args);
    va_end(args);
    return written < 0 ? 0 : static_cast<u64>(written);
}

u64 FileLength(FileHandle* file)
{
    if (!file)
        return 0;

    const auto old = ftello(file->file);
    if (old < 0)
        return 0;
    if (fseeko(file->file, 0, SEEK_END) != 0)
        return 0;
    const auto len = ftello(file->file);
    fseeko(file->file, old, SEEK_SET);
    return len < 0 ? 0 : static_cast<u64>(len);
}

void Log(LogLevel level, const char* fmt, ...)
{
    if (level == LogLevel::Debug)
        return;

    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    va_end(args);
}

Thread* Thread_Create(std::function<void()> func)
{
    return new Thread {std::thread(std::move(func))};
}

void Thread_Free(Thread* thread)
{
    delete thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread && thread->thread.joinable())
        thread->thread.join();
}

Semaphore* Semaphore_Create()
{
    return new Semaphore;
}

void Semaphore_Free(Semaphore* sema)
{
    delete sema;
}

void Semaphore_Reset(Semaphore* sema)
{
    if (!sema)
        return;
#if defined(__linux__)
    sema->count.store(0, std::memory_order_release);
#else
    std::lock_guard<std::mutex> lock(sema->mutex);
    sema->count = 0;
#endif
}

void Semaphore_Wait(Semaphore* sema)
{
    if (!sema)
        return;
#if defined(__linux__)
    for (;;) {
        if (semaphore_try_consume(sema->count))
            return;
        sema->waiters.fetch_add(1, std::memory_order_acq_rel);
        // Close the post-before-registration race before sleeping.
        if (semaphore_try_consume(sema->count)) {
            sema->waiters.fetch_sub(1, std::memory_order_release);
            return;
        }
        // FUTEX_WAIT checks the value atomically before sleeping. A producer
        // that posts between the failed consume and this call therefore
        // yields EAGAIN instead of a lost wake-up.
        for (;;) {
            if (futex_wait(sema->count, 0) != 0 &&
                errno != EAGAIN && errno != EINTR)
                // Unexpected kernel errors must not turn an optional
                // optimization into an emulation fault.
                std::this_thread::yield();
            if (semaphore_try_consume(sema->count)) {
                sema->waiters.fetch_sub(1, std::memory_order_release);
                return;
            }
        }
    }
#else
    std::unique_lock<std::mutex> lock(sema->mutex);
    sema->cv.wait(lock, [&] { return sema->count > 0; });
    --sema->count;
#endif
}

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    if (!sema)
        return false;

#if defined(__linux__)
    if (semaphore_try_consume(sema->count))
        return true;
    if (timeout_ms <= 0)
        return false;

    sema->waiters.fetch_add(1, std::memory_order_acq_rel);
    if (semaphore_try_consume(sema->count)) {
        sema->waiters.fetch_sub(1, std::memory_order_release);
        return true;
    }
    const auto deadline =
        std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeout_ms);
    for (;;) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            sema->waiters.fetch_sub(1, std::memory_order_release);
            return false;
        }
        const auto remaining = std::chrono::duration_cast<
            std::chrono::nanoseconds>(deadline - now);
        timespec timeout {};
        timeout.tv_sec = static_cast<time_t>(
            remaining.count() / 1000000000ll);
        timeout.tv_nsec = static_cast<long>(
            remaining.count() % 1000000000ll);
        const int result = futex_wait(sema->count, 0, &timeout);
        if (semaphore_try_consume(sema->count)) {
            sema->waiters.fetch_sub(1, std::memory_order_release);
            return true;
        }
        if (result != 0 && errno == ETIMEDOUT) {
            sema->waiters.fetch_sub(1, std::memory_order_release);
            return false;
        }
        if (result == 0 || errno == EAGAIN || errno == EINTR)
            continue;
        std::this_thread::yield();
    }
#else
    std::unique_lock<std::mutex> lock(sema->mutex);
    const auto ready = [&] { return sema->count > 0; };
    if (timeout_ms == 0) {
        if (!ready())
            return false;
    } else if (!sema->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), ready)) {
        return false;
    }

    --sema->count;
    return true;
#endif
}

void Semaphore_Post(Semaphore* sema, int count)
{
    if (!sema || count <= 0)
        return;
#if defined(__linux__)
    const auto previous = sema->count.fetch_add(
        count, std::memory_order_release);
    if (previous == 0 &&
        sema->waiters.load(std::memory_order_acquire) != 0)
        futex_wake_all(sema->count);
#else
    {
        std::lock_guard<std::mutex> lock(sema->mutex);
        sema->count += count;
    }
    sema->cv.notify_all();
#endif
}

Mutex* Mutex_Create()
{
    return new Mutex;
}

void Mutex_Free(Mutex* mutex)
{
    delete mutex;
}

void Mutex_Lock(Mutex* mutex)
{
    if (mutex)
        mutex->mutex.lock();
}

void Mutex_Unlock(Mutex* mutex)
{
    if (mutex)
        mutex->mutex.unlock();
}

bool Mutex_TryLock(Mutex* mutex)
{
    return mutex && mutex->mutex.try_lock();
}

void Sleep(u64 usecs)
{
    std::this_thread::sleep_for(std::chrono::microseconds(usecs));
}

u64 GetMSCount()
{
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
}

u64 GetUSCount()
{
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::microseconds>(now).count();
}

void WriteNDSSave(const u8* data, u32 length, u32 offset, u32 writeLength,
    void* userdata)
{
    auto* callback = static_cast<nds4mister::HeadlessSaveCallback*>(userdata);
    if (callback && callback->write)
        callback->write(callback->opaque, data, length, offset, writeLength);
}
void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

void MP_Begin(void*) {}
void MP_End(void*) {}
int MP_SendPacket(u8*, int, u64, void*) { return 0; }
int MP_RecvPacket(u8*, u64*, void*) { return 0; }
int MP_SendCmd(u8*, int, u64, void*) { return 0; }
int MP_SendReply(u8*, int, u64, u16, void*) { return 0; }
int MP_SendAck(u8*, int, u64, void*) { return 0; }
int MP_RecvHostPacket(u8*, u64*, void*) { return 0; }
u16 MP_RecvReplies(u8*, u64, u16, void*) { return 0; }

int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }

void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32* frame, int width, int height, bool, void*)
{
    std::memset(frame, 0, static_cast<std::size_t>(width * height) * sizeof(u32));
}

void Mic_Start(void*) {}
void Mic_Stop(void*) {}
int Mic_ReadInput(s16* data, int maxlength, void*)
{
    std::memset(data, 0, static_cast<std::size_t>(maxlength) * sizeof(s16));
    return maxlength;
}

AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType, void*) { return 0.0f; }

DynamicLibrary* DynamicLibrary_Load(const char* lib)
{
    void* handle = dlopen(lib, RTLD_NOW);
    if (!handle)
        return nullptr;
    return new DynamicLibrary {handle};
}

void DynamicLibrary_Unload(DynamicLibrary* lib)
{
    if (!lib)
        return;
    dlclose(lib->handle);
    delete lib;
}

void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name)
{
    return lib ? dlsym(lib->handle, name) : nullptr;
}

} // namespace melonDS::Platform
