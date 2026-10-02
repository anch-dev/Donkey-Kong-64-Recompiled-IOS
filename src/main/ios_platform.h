#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void dk64_ios_prepare_audio(void);
void dk64_ios_prepare_filesystem(void);
void dk64_ios_fix_metal_layer_scale(void* ui_window, void* metal_layer);

#ifdef __cplusplus
}
#endif
