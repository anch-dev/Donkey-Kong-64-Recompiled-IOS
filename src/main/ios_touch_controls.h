#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Creates the on-screen controller overlay on the SDL window (hidden until shown).
void dk64_ios_touch_controls_init(void* sdl_window);
// Shows/hides the overlay. The virtual gamepad is created the first time it is shown.
void dk64_ios_touch_controls_set_visible(int visible);

#ifdef __cplusplus
}
#endif
