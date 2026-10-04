#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Creates the on-screen controller overlay on the SDL window (hidden until shown).
void dk64_ios_touch_controls_init(void* sdl_window);
// Shows/hides the overlay. The virtual gamepad is created the first time it is shown.
void dk64_ios_touch_controls_set_visible(int visible);
// Call regularly from the main thread; (re)creates the overlay window if needed and keeps it visible.
void dk64_ios_touch_controls_tick(void);
// Temporarily hides the overlay (e.g. while a system file picker is on screen).
void dk64_ios_touch_controls_set_suspended(int suspended);

// Returns the SDL window's UIWindow* (as void*), or NULL if not created yet.
void* dk64_ios_ui_window(void);

#ifdef __cplusplus
}
#endif
