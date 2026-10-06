#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Verbose file logging for the iOS port. Everything (stdout, stderr, NSLog, SDL log, crashes) lands in
//   <Documents>/DK64Logs/dk64.log      (current run)
//   <Documents>/DK64Logs/dk64-prev.log (previous run)
void dk64_ios_log_init(void);
void dk64_ios_logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
// Logs SDL window/touch/mouse/controller/keyboard events. Call once after SDL video is initialised.
void dk64_ios_log_install_event_watch(void);
// Call once per rendered frame. Logs a 5 s pacing summary (fps, frame-time spikes, memory, thermal state) and any single
// frame that took >100 ms, so audio crackle can be matched against frame hitches.
void dk64_ios_log_frame_tick(void);
// Logs a snapshot of window geometry/scale for diagnosing layout problems.
void dk64_ios_log_window_info(void* sdl_window);

#ifdef __cplusplus
}
#endif

#define DK64_LOG(...) dk64_ios_logf(__VA_ARGS__)
