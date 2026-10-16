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
// Rotates every window scene to landscape now, and again whenever the app becomes active. Needed because the Info.plist
// orientation list is ignored when running inside LiveContainer (the host app's list applies, which allows portrait).
void dk64_ios_force_landscape(void);
// Saves (ios_saves.mm): makes the save and mods folders visible in the Files app (Documents/Saves, Documents/Mods),
// moving existing data there, and backs the save up to Documents/Saves/Backups if it changed. Call before the game starts.
void dk64_ios_prepare_save_folders(void);
// Shows the launcher's "Saves & ROM" sheet: export/import the save, open the saves folder, and (if a ROM is loaded)
// replace the ROM, which reports back through `replace_rom_done`.
void dk64_ios_show_data_menu(int rom_ready, DK64PickDone replace_rom_done);

#ifdef __cplusplus
}
#endif
