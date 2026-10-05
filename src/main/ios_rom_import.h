#pragma once
// ROM staging/import for the iOS port (Objective-C++ only).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DK64RomImportStatus) {
    DK64RomImportOK = 0,
    DK64RomImportCannotAccess,  // "Unable to access the selected file"
    DK64RomImportCopyFailed,    // "ROM copy failed"
    DK64RomImportNotARom,       // "Invalid N64 ROM"
    DK64RomImportBadSize,       // "Unsupported ROM format" (not a 32 MB cartridge image)
};

#ifdef __cplusplus
extern "C" {
#endif

// Human readable message for a status (used for alerts and logs).
NSString *dk64_rom_status_message(DK64RomImportStatus status);

// Header + size check of an on-disk ROM in any of the three N64 byte orders.
// byteOrder: 0 = .z64 (80 37 12 40), 1 = .v64 (37 80 40 12), 2 = .n64 (40 12 37 80). May be NULL.
DK64RomImportStatus dk64_rom_check_file(NSString *path, int *byteOrder);

// Copies `source` into app-controlled storage at `destination`, normalised to .z64 byte order.
//   security-scoped access -> coordinated read -> stream into a temp file in the destination folder ->
//   verify size -> fsync -> atomic rename. A partial copy is never left at `destination`.
DK64RomImportStatus dk64_import_rom(NSURL *source, NSString *destination, NSString **detail);

// <Application Support>/DK64Recompiled/ROMs (created on demand).
NSString *dk64_rom_staging_directory(void);

// Removes leftover ".import-*.tmp" files from interrupted imports in the given folders.
void dk64_rom_cleanup_temp_files(void);

#ifdef __cplusplus
}
#endif
