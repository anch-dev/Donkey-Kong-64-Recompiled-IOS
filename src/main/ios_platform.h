#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void dk64_ios_prepare_audio(void);
void dk64_ios_prepare_filesystem(void);
void dk64_ios_import_rom_from_documents(void);
// 1 if a stored ROM file (<Application Support>/DK64Recompiled/DK64.z64) existed when the app started, before librecomp's
// hash check (which deletes a stored ROM with the wrong hash). Lets the launcher tell "missing" from "invalid".
int dk64_ios_rom_stored_at_boot(void);
// Asynchronous ROM picker + importer (ios_nfd.mm). `done` runs once on the main thread with a local copy of the ROM.
typedef void (*DK64PickDone)(void* context, int success, const char* path);
void dk64_ios_pick_rom_async(DK64PickDone done, void* context);
void dk64_ios_fix_metal_layer_scale(void* ui_window, void* metal_layer);

#ifdef __cplusplus
}
#endif
