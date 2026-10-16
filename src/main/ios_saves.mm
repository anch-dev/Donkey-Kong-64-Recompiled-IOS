// Save data on iOS: visible in the Files app, automatically backed up, and exportable/importable from the launcher.
//
// The runtime keeps its data in <Application Support>/DK64Recompiled (hidden from Files): the save is saves/DK64.bin
// (16 kbit EEPROM, 2 KB) and mods live in mods/. Both folders are replaced by symlinks into the app's Documents folder
// (Documents/Saves, Documents/Mods), which Files shows because Info.plist enables file sharing. The runtime keeps using
// its usual paths and simply writes through the links.
//
// Real iCloud sync would need an iCloud entitlement, which sideloaded/LiveContainer builds cannot have. Instead the save
// can be exported through the share sheet (Save to Files / iCloud Drive / AirDrop / ...) and imported back from Files,
// and iOS device backups include Documents.
#include "ios_platform.h"
#include "ios_log.h"
#import "ios_ui.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString* const kSaveFileName = @"DK64.bin";
static const NSUInteger kSaveSize = 0x800;          // recomp::SaveType::Eep16k
static const NSUInteger kRetroArchSrmSize = 0x48800; // mupen64plus-libretro .srm: EEPROM is its first 0x800 bytes
static const NSUInteger kMaxBackups = 10;

static NSString* documents_dir(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
}

static NSString* app_data_dir(void) {
    NSURL* support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"DK64Recompiled" isDirectory:YES].path;
}

static NSString* saves_dir(void) { return [documents_dir() stringByAppendingPathComponent:@"Saves"]; }
static NSString* backups_dir(void) { return [saves_dir() stringByAppendingPathComponent:@"Backups"]; }
static NSString* save_file(void) { return [saves_dir() stringByAppendingPathComponent:kSaveFileName]; }

// Makes `linkPath` a symlink to the real folder `target`, moving anything that was stored at `linkPath` into `target`.
// Runs every launch, so it also repairs a link left pointing at an old container path after an app update.
static void link_folder(NSString* linkPath, NSString* target, NSString* relativeTarget) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSError* error = nil;
    [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];

    NSDictionary* attrs = [fm attributesOfItemAtPath:linkPath error:nil];  // does not follow a final symlink
    NSString* type = attrs[NSFileType];
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
        NSString* current = [fm destinationOfSymbolicLinkAtPath:linkPath error:nil];
        if ([current isEqualToString:relativeTarget]) {
            return;
        }
        DK64_LOG("FILES: relinking %s (was -> %s)", linkPath.UTF8String, current.UTF8String);
        [fm removeItemAtPath:linkPath error:nil];
    } else if ([type isEqualToString:NSFileTypeDirectory]) {
        // First launch with this build: move the existing hidden folder's contents into the visible one.
        for (NSString* name in [fm contentsOfDirectoryAtPath:linkPath error:nil]) {
            NSString* from = [linkPath stringByAppendingPathComponent:name];
            NSString* to = [target stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:to]) {
                // Never overwrite: keep the one already in the visible folder and set the other aside.
                to = [target stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (moved %@)", name,
                                                                                       @((long long)NSDate.date.timeIntervalSince1970)]];
            }
            if (![fm moveItemAtPath:from toPath:to error:&error]) {
                DK64_LOG("FILES: could not move %s into %s: %s; leaving the hidden folder in place", from.UTF8String, target.UTF8String,
                         error.localizedDescription.UTF8String);
                return;  // the runtime keeps working from the hidden folder
            }
            DK64_LOG("FILES: moved %s -> %s", from.UTF8String, to.UTF8String);
        }
        if (![fm removeItemAtPath:linkPath error:&error]) {
            DK64_LOG("FILES: could not remove %s: %s", linkPath.UTF8String, error.localizedDescription.UTF8String);
            return;
        }
    } else if (type != nil) {
        DK64_LOG("FILES: %s is an unexpected %s; not touching it", linkPath.UTF8String, type.UTF8String);
        return;
    }

    if (![fm createSymbolicLinkAtPath:linkPath withDestinationPath:relativeTarget error:&error]) {
        DK64_LOG("FILES: symlink %s -> %s failed: %s", linkPath.UTF8String, relativeTarget.UTF8String, error.localizedDescription.UTF8String);
        return;
    }
    DK64_LOG("FILES: %s -> %s", linkPath.UTF8String, relativeTarget.UTF8String);
}

// Link target as seen from the app data folder: relative when the usual container layout holds, so the link survives the
// container moving to a new path on app updates; absolute otherwise (it is re-checked every launch anyway).
static NSString* link_target(NSString* visibleFolderName) {
    NSString* home = [documents_dir() stringByDeletingLastPathComponent];
    NSString* expectedAppData = [[home stringByAppendingPathComponent:@"Library/Application Support"] stringByAppendingPathComponent:@"DK64Recompiled"];
    if ([expectedAppData isEqualToString:app_data_dir()]) {
        return [@"../../../Documents" stringByAppendingPathComponent:visibleFolderName];
    }
    return [documents_dir() stringByAppendingPathComponent:visibleFolderName];
}

static NSString* timestamp(void) {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HHmmss";
    return [formatter stringFromDate:NSDate.date];
}

static NSArray<NSString*>* sorted_backups(void) {
    NSArray<NSString*>* names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:backups_dir() error:nil] ?: @[];
    NSMutableArray<NSString*>* backups = [NSMutableArray array];
    for (NSString* name in names) {
        if ([name hasPrefix:@"DK64 "] && [name.pathExtension isEqualToString:@"bin"]) [backups addObject:name];
    }
    return [backups sortedArrayUsingSelector:@selector(compare:)];  // timestamped names sort oldest -> newest
}

// Copies the current save into Saves/Backups unless it is identical to the newest backup, then keeps the newest few.
static void backup_save(NSString* reason) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSData* current = [NSData dataWithContentsOfFile:save_file()];
    if (current.length == 0) return;

    [fm createDirectoryAtPath:backups_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSString*>* backups = sorted_backups();
    NSData* newest = backups.count > 0 ? [NSData dataWithContentsOfFile:[backups_dir() stringByAppendingPathComponent:backups.lastObject]] : nil;
    if ([newest isEqualToData:current]) return;

    NSString* name = [NSString stringWithFormat:@"DK64 %@.bin", timestamp()];
    if ([current writeToFile:[backups_dir() stringByAppendingPathComponent:name] atomically:YES]) {
        DK64_LOG("SAVES: backed up save (%s) -> Backups/%s", reason.UTF8String, name.UTF8String);
    }
    backups = sorted_backups();
    for (NSUInteger i = 0; i + kMaxBackups < backups.count; i++) {
        [fm removeItemAtPath:[backups_dir() stringByAppendingPathComponent:backups[i]] error:nil];
    }
}

extern "C" void dk64_ios_prepare_save_folders(void) {
    NSString* appData = app_data_dir();
    if (documents_dir() == nil || appData == nil) return;
    [NSFileManager.defaultManager createDirectoryAtPath:appData withIntermediateDirectories:YES attributes:nil error:nil];
    link_folder([appData stringByAppendingPathComponent:@"saves"], saves_dir(), link_target(@"Saves"));
    link_folder([appData stringByAppendingPathComponent:@"mods"], [documents_dir() stringByAppendingPathComponent:@"Mods"], link_target(@"Mods"));
    backup_save(@"launch");
}

// ---- Launcher "Saves & ROM" menu -----------------------------------------------------------------------------------

static void present_sheet(UIViewController* sheet) {
    UIViewController* top = dk64_ios_top_view_controller();
    if (top == nil) return;
    // iPad shows action sheets and share sheets as popovers, which need an anchor.
    sheet.popoverPresentationController.sourceView = top.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
    sheet.popoverPresentationController.permittedArrowDirections = 0;
    [top presentViewController:sheet animated:YES completion:nil];
}

static void export_save(void) {
    NSData* data = [NSData dataWithContentsOfFile:save_file()];
    if (data.length == 0) {
        dk64_ios_show_alert(@"Export Save", @"There is no save yet. Start the game and save once first.");
        return;
    }
    // Share a dated copy so the exported file has a meaningful name and the live save is never handed out.
    NSString* name = [NSString stringWithFormat:@"DK64 Save %@.bin", timestamp()];
    NSString* exportDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SaveExport"];
    [NSFileManager.defaultManager removeItemAtPath:exportDir error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:exportDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* path = [exportDir stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) {
        dk64_ios_show_alert(@"Export Save", @"Could not prepare the save for export.");
        return;
    }
    UIActivityViewController* share = [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
                                                                        applicationActivities:nil];
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray*, NSError* error) {
        DK64_LOG("SAVES: export %s via %s%s", completed ? "done" : "cancelled", type.UTF8String ?: "-",
                 error != nil ? error.localizedDescription.UTF8String : "");
    };
    present_sheet(share);
}

static void import_save(void) {
    dk64_ios_pick_file(^(NSURL* url, NSString* error) {
        if (error != nil) {
            dk64_ios_show_alert(@"Import Save", error);
            return;
        }
        if (url == nil) return;  // cancelled

        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData* data = [NSData dataWithContentsOfURL:url];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dk64_ios_discard_picker_copy(url);

        if (data.length == kRetroArchSrmSize) {
            data = [data subdataWithRange:NSMakeRange(0, kSaveSize)];  // RetroArch (mupen64plus) combined save
        }
        if (data.length != kSaveSize) {
            dk64_ios_show_alert(@"Import Save", [NSString stringWithFormat:@"That file is not a DK64 save (%lu bytes; a DK64 save is "
                                                                              @"%lu bytes). Your current save was not changed.",
                                                                              (unsigned long)data.length, (unsigned long)kSaveSize]);
            return;
        }

        backup_save(@"before import");
        [NSFileManager.defaultManager createDirectoryAtPath:saves_dir() withIntermediateDirectories:YES attributes:nil error:nil];
        NSError* writeError = nil;
        if (![data writeToFile:save_file() options:NSDataWritingAtomic error:&writeError]) {
            dk64_ios_show_alert(@"Import Save", [NSString stringWithFormat:@"Could not write the save: %@", writeError.localizedDescription]);
            return;
        }
        // The runtime falls back to DK64.bin.bak when DK64.bin is unreadable; keep that copy in step with the import.
        [data writeToFile:[save_file() stringByAppendingString:@".bak"] atomically:YES];
        DK64_LOG("SAVES: imported %s (%lu bytes)", url.lastPathComponent.UTF8String, (unsigned long)data.length);
        dk64_ios_show_alert(@"Import Save", @"Save imported. Your previous save was kept in Saves/Backups.");
    });
}

static void open_saves_folder(void) {
    // The Files app opens a folder inside an app container through the shareddocuments:// scheme.
    NSString* path = [saves_dir() stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL* url = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:path]];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        DK64_LOG("SAVES: open in Files %s", success ? "ok" : "FAILED");
        if (!success) {
            dk64_ios_show_alert(@"Saves Folder", @"Open the Files app and go to On My iPhone > DK64 Recompiled > Saves "
                                                 @"(inside LiveContainer: LiveContainer > Data > Application > ... > Saves).");
        }
    }];
}

extern "C" void dk64_ios_show_data_menu(int rom_ready, DK64PickDone replace_rom_done) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL hasSave = [NSFileManager.defaultManager fileExistsAtPath:save_file()];
        NSString* message = hasSave ? @"Your save is in the Files app under Saves. A backup is made automatically each launch."
                                    : @"No save yet. Saves appear in the Files app under Saves.";
        UIAlertController* sheet = [UIAlertController alertControllerWithTitle:@"Saves & ROM" message:message
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Export Save…" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction*) { export_save(); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Import Save…" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction*) { import_save(); }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Show Saves in Files" style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction*) { open_saves_folder(); }]];
        if (rom_ready) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"Replace ROM…" style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction*) { dk64_ios_pick_rom_async(replace_rom_done, nullptr); }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        present_sheet(sheet);
    });
}
