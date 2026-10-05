#import "ios_rom_import.h"
#include <algorithm>
#include <cerrno>
#include "ios_log.h"

#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

static const unsigned long long kDK64RomSize = 33554432ULL;  // NTSC-U cartridge image: 32 MiB
static const size_t kChunk = 1 << 20;                        // multiple of 4, required by the byte swapping below

static NSString *DK64AppDataDirectory() {
    NSURL *appSupport = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                               inDomain:NSUserDomainMask
                                                      appropriateForURL:nil
                                                                 create:YES
                                                                  error:nil];
    return [appSupport URLByAppendingPathComponent:@"DK64Recompiled" isDirectory:YES].path;
}

NSString *dk64_rom_staging_directory(void) {
    NSString *dir = [DK64AppDataDirectory() stringByAppendingPathComponent:@"ROMs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSString *dk64_rom_status_message(DK64RomImportStatus status) {
    switch (status) {
    case DK64RomImportOK: return @"OK";
    case DK64RomImportCannotAccess: return @"Unable to access the selected file.";
    case DK64RomImportCopyFailed: return @"ROM copy failed. Make sure the device has enough free storage and try again.";
    case DK64RomImportNotARom: return @"Invalid N64 ROM. The file is not a Nintendo 64 ROM image.";
    case DK64RomImportBadSize: return @"Unsupported ROM format. Donkey Kong 64 (NTSC-U) is a 32 MB ROM.";
    }
    return @"Unknown error.";
}

static int ByteOrderFromHeader(const uint8_t *h) {
    if (h[0] == 0x80 && h[1] == 0x37 && h[2] == 0x12 && h[3] == 0x40) return 0;  // .z64 big endian
    if (h[0] == 0x37 && h[1] == 0x80 && h[2] == 0x40 && h[3] == 0x12) return 1;  // .v64 byte swapped
    if (h[0] == 0x40 && h[1] == 0x12 && h[2] == 0x37 && h[3] == 0x80) return 2;  // .n64 little endian
    return -1;
}

DK64RomImportStatus dk64_rom_check_file(NSString *path, int *byteOrder) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return DK64RomImportCannotAccess;
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (f == nullptr) return DK64RomImportCannotAccess;
    uint8_t header[4] = {};
    size_t got = fread(header, 1, 4, f);
    fclose(f);
    int order = got == 4 ? ByteOrderFromHeader(header) : -1;
    if (order < 0) return DK64RomImportNotARom;
    if (byteOrder != nullptr) *byteOrder = order;
    if ((unsigned long long)st.st_size != kDK64RomSize) return DK64RomImportBadSize;
    return DK64RomImportOK;
}

static void SwapToZ64(uint8_t *data, size_t length, int order) {
    if (order == 1) {
        for (size_t i = 0; i + 1 < length; i += 2) std::swap(data[i], data[i + 1]);
    } else if (order == 2) {
        for (size_t i = 0; i + 3 < length; i += 4) {
            std::swap(data[i], data[i + 3]);
            std::swap(data[i + 1], data[i + 2]);
        }
    }
}

// Streams `readURL` into `tmpPath`, normalising the byte order. Never holds the whole ROM in memory.
static DK64RomImportStatus CopyNormalised(NSURL *readURL, NSString *tmpPath, NSString **detail) {
    struct stat st;
    if (stat(readURL.fileSystemRepresentation, &st) != 0) {
        if (detail) *detail = [NSString stringWithFormat:@"stat failed (errno %d)", errno];
        return DK64RomImportCannotAccess;
    }
    if (!S_ISREG(st.st_mode)) return DK64RomImportNotARom;
    if ((unsigned long long)st.st_size != kDK64RomSize) {
        if (detail) *detail = [NSString stringWithFormat:@"file is %lld bytes, expected %llu", (long long)st.st_size, kDK64RomSize];
        return DK64RomImportBadSize;  // rejected before copying anything
    }

    FILE *in = fopen(readURL.fileSystemRepresentation, "rb");
    if (in == nullptr) {
        if (detail) *detail = [NSString stringWithFormat:@"open failed (errno %d)", errno];
        return DK64RomImportCannotAccess;
    }
    FILE *out = fopen(tmpPath.fileSystemRepresentation, "wb");
    if (out == nullptr) {
        fclose(in);
        if (detail) *detail = [NSString stringWithFormat:@"cannot create temp file (errno %d)", errno];
        return DK64RomImportCopyFailed;
    }

    std::vector<uint8_t> buffer(kChunk);
    unsigned long long total = 0;
    int order = -1;
    DK64RomImportStatus status = DK64RomImportOK;
    while (true) {
        size_t n = fread(buffer.data(), 1, kChunk, in);
        if (n == 0) {
            if (ferror(in)) {
                status = DK64RomImportCannotAccess;
                if (detail) *detail = [NSString stringWithFormat:@"read failed at %llu bytes (errno %d)", total, errno];
            }
            break;
        }
        if (total == 0) {
            order = n >= 4 ? ByteOrderFromHeader(buffer.data()) : -1;
            if (order < 0) {
                status = DK64RomImportNotARom;
                break;
            }
            DK64_LOG("ROM import: byte order %s", order == 0 ? "z64" : (order == 1 ? "v64" : "n64"));
        }
        SwapToZ64(buffer.data(), n & ~(size_t)3, order);
        if (fwrite(buffer.data(), 1, n, out) != n) {
            status = DK64RomImportCopyFailed;
            if (detail) *detail = [NSString stringWithFormat:@"write failed at %llu bytes (errno %d)", total, errno];
            break;
        }
        total += n;
    }
    fclose(in);
    if (status == DK64RomImportOK) {
        if (fflush(out) != 0 || fsync(fileno(out)) != 0) status = DK64RomImportCopyFailed;
    }
    fclose(out);

    if (status == DK64RomImportOK) {
        struct stat copied;
        if (total != kDK64RomSize || stat(tmpPath.fileSystemRepresentation, &copied) != 0 || (unsigned long long)copied.st_size != total) {
            if (detail) *detail = [NSString stringWithFormat:@"verification failed (read %llu bytes)", total];
            status = DK64RomImportCopyFailed;
        }
    }
    return status;
}

DK64RomImportStatus dk64_import_rom(NSURL *source, NSString *destination, NSString **detail) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *folder = destination.stringByDeletingLastPathComponent;
    NSError *error = nil;
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (detail) *detail = error.localizedDescription;
        return DK64RomImportCopyFailed;
    }
    NSString *tmp = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@".import-%@.tmp", [[NSUUID UUID] UUIDString]]];

    // Files chosen from outside the sandbox are security-scoped. (Import-mode picks are already local copies, for which
    // this simply returns NO; both cases are handled.)
    BOOL scoped = [source startAccessingSecurityScopedResource];
    DK64_LOG("ROM import: source=%s securityScoped=%d -> %s", source.path.UTF8String, (int)scoped, destination.UTF8String);

    __block DK64RomImportStatus status = DK64RomImportCannotAccess;
    __block NSString *blockDetail = nil;
    NSError *coordinationError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinationError
                                 byAccessor:^(NSURL *readURL) {
                                     status = CopyNormalised(readURL, tmp, &blockDetail);
                                 }];
    if (scoped) [source stopAccessingSecurityScopedResource];

    if (coordinationError != nil && status != DK64RomImportOK) {
        blockDetail = coordinationError.localizedDescription;
        status = DK64RomImportCannotAccess;
    }
    if (status == DK64RomImportOK) {
        // Atomic replace: readers see either the old file or the complete new one, never a partial copy.
        if (rename(tmp.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
            blockDetail = [NSString stringWithFormat:@"rename failed (errno %d)", errno];
            status = DK64RomImportCopyFailed;
        }
    }
    if (status != DK64RomImportOK) {
        unlink(tmp.fileSystemRepresentation);
        DK64_LOG("ROM import FAILED: %s (%s)", dk64_rom_status_message(status).UTF8String, blockDetail ? blockDetail.UTF8String : "-");
    } else {
        DK64_LOG("ROM import OK: %s (%llu bytes)", destination.UTF8String, kDK64RomSize);
    }
    if (detail) *detail = blockDetail;
    return status;
}

void dk64_rom_cleanup_temp_files(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[ DK64AppDataDirectory(), [DK64AppDataDirectory() stringByAppendingPathComponent:@"ROMs"] ]) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([name hasPrefix:@".import-"] && [name hasSuffix:@".tmp"]) {
                DK64_LOG("ROM import: removing leftover %s", name.UTF8String);
                [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
            }
        }
    }
}
