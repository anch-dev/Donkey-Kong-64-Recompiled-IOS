// Verbose logging for the iOS port. Intentionally dependency-free so it can be initialised first thing in main().
#include <string>
#include <algorithm>
#include "ios_log.h"

#include <SDL2/SDL.h>

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

static int g_log_fd = -1;
static char g_log_path[1024] = {};

static void write_all(const char* data, size_t len) {
    int fd = g_log_fd >= 0 ? g_log_fd : STDERR_FILENO;
    while (len > 0) {
        ssize_t n = write(fd, data, len);
        if (n <= 0) return;
        data += n;
        len -= (size_t)n;
    }
}

static size_t timestamp(char* out, size_t cap) {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    struct tm tmv;
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &tmv);
    uint64_t tid = 0;
    pthread_threadid_np(nullptr, &tid);
    int n = snprintf(out, cap, "[%02d:%02d:%02d.%03d t%llu] ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000),
                     (unsigned long long)tid);
    return n > 0 ? (size_t)n : 0;
}

extern "C" void dk64_ios_logf(const char* fmt, ...) {
    char buf[2048];
    size_t off = timestamp(buf, sizeof(buf));
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(buf + off, sizeof(buf) - off - 2, fmt, args);
    va_end(args);
    if (n < 0) return;
    size_t len = off + (size_t)n;
    if (len > sizeof(buf) - 2) len = sizeof(buf) - 2;
    buf[len++] = '\n';
    write_all(buf, len);
}

static uint64_t resident_mb() {
    mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.resident_size / (1024 * 1024);
}

static void crash_handler(int sig, siginfo_t* info, void*) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "\n==== CRASH: signal %d (%s) fault address %p ====\n", sig, strsignal(sig), info ? info->si_addr : nullptr);
    write_all(buf, (size_t)n);
    void* frames[64];
    int count = backtrace(frames, 64);
    int fd = g_log_fd >= 0 ? g_log_fd : STDERR_FILENO;
    backtrace_symbols_fd(frames, count, fd);
    const char* end = "==== end of crash report ====\n";
    write_all(end, strlen(end));
    fsync(fd);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void exception_handler(NSException* exception) {
    dk64_ios_logf("==== UNCAUGHT EXCEPTION: %s: %s", exception.name.UTF8String, exception.reason.UTF8String);
    for (NSString* line in exception.callStackSymbols) {
        dk64_ios_logf("    %s", line.UTF8String);
    }
}

static void sdl_log_output(void*, int category, SDL_LogPriority priority, const char* message) {
    static const char* names[] = {"?", "VERBOSE", "DEBUG", "INFO", "WARN", "ERROR", "CRITICAL"};
    const char* level = (priority > 0 && priority < 7) ? names[priority] : "?";
    dk64_ios_logf("SDL[%d/%s] %s", category, level, message);
}

static void log_directory(const char* label, NSURL* dir) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSURL*>* items = [fm contentsOfDirectoryAtURL:dir
                               includingPropertiesForKeys:@[ NSURLFileSizeKey, NSURLIsDirectoryKey ]
                                                  options:0
                                                    error:nil];
    dk64_ios_logf("%s: %s (%lu items)", label, dir.path.UTF8String, (unsigned long)items.count);
    for (NSURL* item in items) {
        NSNumber* size = nil;
        NSNumber* isDir = nil;
        [item getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        dk64_ios_logf("    %s%s  %llu bytes", item.lastPathComponent.UTF8String, isDir.boolValue ? "/" : "", size.unsignedLongLongValue);
    }
}

extern "C" void dk64_ios_log_init(void) {
    static bool done = false;
    if (done) return;
    done = true;

    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (documents != nil) {
        NSURL* dir = [documents URLByAppendingPathComponent:@"DK64Logs" isDirectory:YES];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL* current = [dir URLByAppendingPathComponent:@"dk64.log"];
        NSURL* previous = [dir URLByAppendingPathComponent:@"dk64-prev.log"];
        [fm removeItemAtURL:previous error:nil];
        if ([fm fileExistsAtPath:current.path]) {
            [fm moveItemAtURL:current toURL:previous error:nil];
        }
        strlcpy(g_log_path, current.path.fileSystemRepresentation, sizeof(g_log_path));
        g_log_fd = open(g_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (g_log_fd >= 0) {
        // Capture printf/fprintf/NSLog output from every library (RmlUi, RT64, librecomp, ...).
        dup2(g_log_fd, STDOUT_FILENO);
        dup2(g_log_fd, STDERR_FILENO);
        setvbuf(stdout, nullptr, _IOLBF, 0);
        setvbuf(stderr, nullptr, _IONBF, 0);
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (int sig : {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP}) {
        sigaction(sig, &sa, nullptr);
    }
    NSSetUncaughtExceptionHandler(&exception_handler);

    SDL_LogSetAllPriority(SDL_LOG_PRIORITY_VERBOSE);
    SDL_LogSetOutputFunction(sdl_log_output, nullptr);

    size_t size = 0;
    sysctlbyname("hw.machine", nullptr, &size, nullptr, 0);
    std::string machine(size, '\0');
    sysctlbyname("hw.machine", machine.data(), &size, nullptr, 0);
    NSBundle* bundle = [NSBundle mainBundle];
    UIDevice* device = [UIDevice currentDevice];
    dk64_ios_logf("==== DK64 Recompiled iOS log ====");
    dk64_ios_logf("log file: %s", g_log_path);
    dk64_ios_logf("app: %s v%s (build %s)", bundle.bundleIdentifier.UTF8String,
                  [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ? [[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] UTF8String] : "?",
                  [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ? [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String] : "?");
    dk64_ios_logf("device: %s, iOS %s, %s", machine.c_str(), device.systemVersion.UTF8String, device.model.UTF8String);
    dk64_ios_logf("physical memory: %llu MB, resident now: %llu MB, cores: %lu, low power: %d, thermal state: %ld",
                  (unsigned long long)(NSProcessInfo.processInfo.physicalMemory / (1024 * 1024)), (unsigned long long)resident_mb(),
                  (unsigned long)NSProcessInfo.processInfo.activeProcessorCount, (int)NSProcessInfo.processInfo.lowPowerModeEnabled,
                  (long)NSProcessInfo.processInfo.thermalState);
    UIScreen* screen = UIScreen.mainScreen;
    dk64_ios_logf("screen: bounds=%s scale=%.2f nativeScale=%.2f nativeBounds=%s", NSStringFromCGRect(screen.bounds).UTF8String, screen.scale,
                  screen.nativeScale, NSStringFromCGRect(screen.nativeBounds).UTF8String);
    dk64_ios_logf("bundle path: %s", bundle.bundlePath.UTF8String);
    char cwd[1024] = {};
    getcwd(cwd, sizeof(cwd));
    dk64_ios_logf("cwd: %s", cwd);
    dk64_ios_logf("env: HOME=%s LC_HOME_PATH=%s", getenv("HOME") ? getenv("HOME") : "(null)", getenv("LC_HOME_PATH") ? getenv("LC_HOME_PATH") : "(not LiveContainer?)");
    if (documents != nil) log_directory("Documents", documents);
    NSURL* appSupport = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (appSupport != nil) log_directory("Application Support", appSupport);

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    NSOperationQueue* main = [NSOperationQueue mainQueue];
    NSArray<NSArray<id>*>* events = @[
        @[ UIApplicationDidBecomeActiveNotification, @"app became active" ],
        @[ UIApplicationWillResignActiveNotification, @"app will resign active" ],
        @[ UIApplicationDidEnterBackgroundNotification, @"app entered background" ],
        @[ UIApplicationWillEnterForegroundNotification, @"app will enter foreground" ],
        @[ UIApplicationWillTerminateNotification, @"app will terminate" ],
    ];
    for (NSArray<id>* e in events) {
        NSString* label = e[1];
        [center addObserverForName:e[0] object:nil queue:main usingBlock:^(NSNotification*) {
            dk64_ios_logf("LIFECYCLE: %s (resident %llu MB)", label.UTF8String, (unsigned long long)resident_mb());
        }];
    }
    [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:main usingBlock:^(NSNotification*) {
        dk64_ios_logf("!!! MEMORY WARNING (resident %llu MB)", (unsigned long long)resident_mb());
    }];
    [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:main usingBlock:^(NSNotification*) {
        dk64_ios_logf("thermal state changed: %ld", (long)NSProcessInfo.processInfo.thermalState);
    }];
}

static int event_watch(void*, SDL_Event* e) {
    static Uint32 last_motion_log = 0;
    switch (e->type) {
    case SDL_WINDOWEVENT:
        dk64_ios_logf("EVENT window event=%d data=(%d,%d)", e->window.event, e->window.data1, e->window.data2);
        break;
    case SDL_FINGERDOWN:
    case SDL_FINGERUP:
        dk64_ios_logf("EVENT finger %s id=%lld pos=(%.3f,%.3f)", e->type == SDL_FINGERDOWN ? "down" : "up", (long long)e->tfinger.fingerId,
                      e->tfinger.x, e->tfinger.y);
        break;
    case SDL_FINGERMOTION:
    case SDL_MOUSEMOTION:
        if (SDL_GetTicks() - last_motion_log > 250) {
            last_motion_log = SDL_GetTicks();
            if (e->type == SDL_MOUSEMOTION) {
                dk64_ios_logf("EVENT mouse motion pos=(%d,%d) which=%u (throttled)", e->motion.x, e->motion.y, e->motion.which);
            } else {
                dk64_ios_logf("EVENT finger motion id=%lld pos=(%.3f,%.3f) (throttled)", (long long)e->tfinger.fingerId, e->tfinger.x, e->tfinger.y);
            }
        }
        break;
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
        dk64_ios_logf("EVENT mouse button %d %s pos=(%d,%d) which=%u (touch-synth=%d)", e->button.button, e->type == SDL_MOUSEBUTTONDOWN ? "down" : "up",
                      e->button.x, e->button.y, e->button.which, e->button.which == SDL_TOUCH_MOUSEID);
        break;
    case SDL_CONTROLLERBUTTONDOWN:
    case SDL_CONTROLLERBUTTONUP:
        dk64_ios_logf("EVENT controller %d button %d %s", e->cbutton.which, e->cbutton.button, e->type == SDL_CONTROLLERBUTTONDOWN ? "down" : "up");
        break;
    case SDL_CONTROLLERDEVICEADDED:
    case SDL_CONTROLLERDEVICEREMOVED:
        dk64_ios_logf("EVENT controller device %s which=%d", e->type == SDL_CONTROLLERDEVICEADDED ? "added" : "removed", e->cdevice.which);
        break;
    case SDL_KEYDOWN:
    case SDL_KEYUP:
        dk64_ios_logf("EVENT key scancode=%d %s", e->key.keysym.scancode, e->type == SDL_KEYDOWN ? "down" : "up");
        break;
    case SDL_QUIT:
        dk64_ios_logf("EVENT SDL_QUIT");
        break;
    case SDL_APP_WILLENTERBACKGROUND:
    case SDL_APP_DIDENTERBACKGROUND:
    case SDL_APP_WILLENTERFOREGROUND:
    case SDL_APP_DIDENTERFOREGROUND:
    case SDL_APP_LOWMEMORY:
    case SDL_APP_TERMINATING:
        dk64_ios_logf("EVENT SDL app lifecycle type=0x%x", e->type);
        break;
    default:
        break;
    }
    return 1;
}

extern "C" void dk64_ios_log_install_event_watch(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;
    SDL_AddEventWatch(event_watch, nullptr);
    dk64_ios_logf("SDL event watch installed");
}

extern "C" void dk64_ios_log_window_info(void* sdl_window) {
    SDL_Window* w = (SDL_Window*)sdl_window;
    if (w == nullptr) return;
    int lw = 0, lh = 0, pw = 0, ph = 0;
    SDL_GetWindowSize(w, &lw, &lh);
    SDL_GetWindowSizeInPixels(w, &pw, &ph);
    dk64_ios_logf("SDL window: logical=%dx%d pixels=%dx%d scale=%.2f flags=0x%x display=%d", lw, lh, pw, ph, lw > 0 ? (double)pw / lw : 0.0,
                  SDL_GetWindowFlags(w), SDL_GetWindowDisplayIndex(w));
    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(0, &mode) == 0) {
        dk64_ios_logf("SDL display 0: %dx%d @%dHz", mode.w, mode.h, mode.refresh_rate);
    }
}

extern "C" void dk64_ios_log_frame_tick(void) {
    static Uint64 window_start = 0, last_frame = 0, last_spike_log = 0;
    static uint32_t frames = 0, hitches25 = 0, hitches50 = 0;
    static double max_dt = 0.0, sum_dt = 0.0;
    static uint32_t summaries = 0;
    const Uint64 freq = SDL_GetPerformanceFrequency();
    const Uint64 now = SDL_GetPerformanceCounter();
    if (window_start == 0) {
        window_start = last_frame = now;
        return;
    }
    const double dt_ms = (now - last_frame) * 1000.0 / freq;
    last_frame = now;
    frames++;
    sum_dt += dt_ms;
    max_dt = std::max(max_dt, dt_ms);
    if (dt_ms > 25.0) hitches25++;
    if (dt_ms > 50.0) hitches50++;
    if (dt_ms > 1500.0) {
        dk64_ios_logf("PERF main loop resumed after a %.0f ms stall (appState=%ld) - e.g. returning from the background", dt_ms,
                      (long)UIApplication.sharedApplication.applicationState);
    }
    if (dt_ms > 100.0 && (now - last_spike_log) * 1000 / freq > 1000) {
        last_spike_log = now;
        dk64_ios_logf("PERF frame spike: %.1f ms (resident %llu MB, thermal %ld)", dt_ms, (unsigned long long)resident_mb(),
                      (long)NSProcessInfo.processInfo.thermalState);
    }
    const double elapsed = (now - window_start) / (double)freq;
    if (elapsed >= 5.0) {
        dk64_ios_logf("PERF 5s: %u frames (%.1f fps) frame ms avg/max=%.1f/%.1f hitches >25ms=%u >50ms=%u | resident=%llu MB thermal=%ld lowPower=%d",
                      frames, frames / elapsed, sum_dt / std::max(frames, 1u), max_dt, hitches25, hitches50, (unsigned long long)resident_mb(),
                      (long)NSProcessInfo.processInfo.thermalState, (int)NSProcessInfo.processInfo.lowPowerModeEnabled);
        frames = hitches25 = hitches50 = 0;
        max_dt = sum_dt = 0.0;
        window_start = now;
        if (++summaries % 6 == 0) {  // every ~30 s
            UIDevice* device = UIDevice.currentDevice;
            device.batteryMonitoringEnabled = YES;
            dk64_ios_logf("HEARTBEAT: uptime=%.0fs battery=%.0f%% state=%ld appState=%ld", NSProcessInfo.processInfo.systemUptime,
                          device.batteryLevel * 100.0, (long)device.batteryState, (long)UIApplication.sharedApplication.applicationState);
        }
    }
}
