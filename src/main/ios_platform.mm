#include "ios_platform.h"
#include "ios_log.h"
#import "ios_rom_import.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_stored_rom_at_boot = 0;

extern "C" int dk64_ios_rom_stored_at_boot(void) { return g_stored_rom_at_boot; }

extern "C" void dk64_ios_prepare_audio(void) {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
                     mode:AVAudioSessionModeDefault
                  options:AVAudioSessionCategoryOptionMixWithOthers
                    error:&error];
    if (error != nil) {
        NSLog(@"[DK64 iOS] AVAudioSession category failed: %@", error);
    }
    error = nil;
    [session setActive:YES error:&error];
    if (error != nil) {
        NSLog(@"[DK64 iOS] AVAudioSession activation failed: %@", error);
    }

    // Diagnostics for crackle/clipping reports.
    NSMutableArray<NSString*>* outputs = [NSMutableArray array];
    for (AVAudioSessionPortDescription* port in session.currentRoute.outputs) {
        [outputs addObject:[NSString stringWithFormat:@"%@(%@)", port.portName, port.portType]];
    }
    DK64_LOG("AUDIO session: category=%s sampleRate=%.0f preferredIOBuffer=%.1fms actualIOBuffer=%.1fms outputLatency=%.1fms route=%s otherAudioPlaying=%d",
             session.category.UTF8String, session.sampleRate, session.preferredIOBufferDuration * 1000.0, session.IOBufferDuration * 1000.0,
             session.outputLatency * 1000.0, [outputs componentsJoinedByString:@","].UTF8String, (int)session.otherAudioPlaying);

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
        DK64_LOG("AUDIO interruption: type=%ld option=%ld", (long)[note.userInfo[AVAudioSessionInterruptionTypeKey] integerValue],
                 (long)[note.userInfo[AVAudioSessionInterruptionOptionKey] integerValue]);
    }];
    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
        AVAudioSession* s = [AVAudioSession sharedInstance];
        DK64_LOG("AUDIO route change: reason=%ld sampleRate=%.0f actualIOBuffer=%.1fms", (long)[note.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue],
                 s.sampleRate, s.IOBufferDuration * 1000.0);
    }];
    [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:nil usingBlock:^(NSNotification*) {
        DK64_LOG("AUDIO media services were reset");
    }];
}

extern "C" void dk64_ios_import_rom_from_documents(void) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSURL*>* documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL* documentsURL = documents.firstObject;
    if (documentsURL == nil) return;

    NSError* error = nil;
    NSArray<NSURL*>* files = [fm contentsOfDirectoryAtURL:documentsURL
                                  includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                     options:NSDirectoryEnumerationSkipsHiddenFiles
                                                       error:&error];
    if (error != nil) {
        NSLog(@"[DK64 iOS] Failed to scan Documents: %@", error);
        return;
    }

    NSURL* appSupport = [fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    if (appSupport == nil) return;
    NSURL* appData = [appSupport URLByAppendingPathComponent:@"DK64Recompiled" isDirectory:YES];
    if (![fm createDirectoryAtURL:appData withIntermediateDirectories:YES attributes:nil error:&error]) return;
    NSURL* destination = [appData URLByAppendingPathComponent:@"DK64.z64"];

    g_stored_rom_at_boot = [fm fileExistsAtPath:destination.path] ? 1 : 0;
    DK64_LOG("ROM: stored ROM present at boot = %d (%s)", g_stored_rom_at_boot, destination.path.UTF8String);

    // Interrupted imports leave only ".import-*.tmp" files; the final ROM is only ever created by an atomic rename.
    dk64_rom_cleanup_temp_files();

    // An imported ROM is persistent: use it automatically when it is still valid.
    if ([fm fileExistsAtPath:destination.path]) {
        int order = -1;
        DK64RomImportStatus existing = dk64_rom_check_file(destination.path, &order);
        if (existing == DK64RomImportOK && order == 0) {
            DK64_LOG("ROM: using stored ROM %s", destination.path.UTF8String);
            return;
        }
        DK64_LOG("ROM: stored ROM is invalid (%s); it is replaced atomically if a valid ROM is found in Documents",
                 dk64_rom_status_message(existing).UTF8String);
    }
    DK64_LOG("ROM import: scanning Documents (%lu files) for .z64/.v64/.n64", (unsigned long)files.count);

    for (NSURL* source in files) {
        NSString* ext = source.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"z64"] && ![ext isEqualToString:@"v64"] && ![ext isEqualToString:@"n64"]) continue;
        DK64_LOG("ROM import: candidate %s", source.lastPathComponent.UTF8String);

        NSString* detail = nil;
        DK64RomImportStatus status = dk64_import_rom(source, destination.path, &detail);
        if (status == DK64RomImportOK) {
            DK64_LOG("ROM imported from Documents: %s -> %s", source.lastPathComponent.UTF8String, destination.path.UTF8String);
            return;  // the user's original file in Documents is left untouched
        }
        DK64_LOG("ROM import: skipped %s (%s)", source.lastPathComponent.UTF8String, dk64_rom_status_message(status).UTF8String);
    }
}

extern "C" void dk64_ios_prepare_filesystem(void) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSURL* appSupport = [fm URLForDirectory:NSApplicationSupportDirectory
                                   inDomain:NSUserDomainMask
                          appropriateForURL:nil
                                     create:YES
                                      error:nil];
    if (appSupport == nil) {
        NSLog(@"[DK64 iOS] Failed to locate Application Support directory");
        return;
    }

    NSString* dk64Directory = [appSupport URLByAppendingPathComponent:@"DK64Recompiled" isDirectory:YES].path;
    NSError* error = nil;
    if (![fm createDirectoryAtPath:dk64Directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"[DK64 iOS] Failed to create app data directory: %@", error);
        return;
    }

    DK64_LOG("FS: app data directory = %s", dk64Directory.UTF8String);
    if (chdir(dk64Directory.fileSystemRepresentation) != 0) {
        DK64_LOG("FS: chdir to %s FAILED", dk64Directory.UTF8String);
    }
}

extern "C" void dk64_ios_fix_metal_layer_scale(void* ui_window, void* metal_layer) {
    UIWindow* window = (__bridge UIWindow*)ui_window;
    CAMetalLayer* layer = (__bridge CAMetalLayer*)metal_layer;
    if (window == nil || layer == nil) return;
    UIScreen* screen = window.screen ?: [UIScreen mainScreen];
    CGFloat scale = screen.nativeScale > 0.0 ? screen.nativeScale : screen.scale;
    if (scale <= 0.0) return;
    layer.contentsScale = scale;
    CGRect bounds = window.bounds;
    layer.drawableSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
}
