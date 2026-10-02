#include "ios_platform.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <sys/stat.h>
#include <unistd.h>

extern "C" void dk64_ios_prepare_audio(void) {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback
                     mode:AVAudioSessionModeGame
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
    if ([fm fileExistsAtPath:destination.path]) return;

    for (NSURL* source in files) {
        NSString* ext = source.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"z64"] && ![ext isEqualToString:@"v64"] && ![ext isEqualToString:@"n64"]) continue;

        NSNumber* regular = nil;
        NSNumber* size = nil;
        [source getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [source getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (![regular boolValue] || size.unsignedLongLongValue != 33554432ULL) continue;

        NSData* input = [NSData dataWithContentsOfURL:source options:NSDataReadingMappedIfSafe error:&error];
        if (input == nil || input.length != 33554432ULL) continue;

        NSMutableData* normalized = [NSMutableData dataWithLength:input.length];
        const uint8_t* in = static_cast<const uint8_t*>(input.bytes);
        uint8_t* out = static_cast<uint8_t*>(normalized.mutableBytes);
        if ([ext isEqualToString:@"z64"]) {
            memcpy(out, in, input.length);
        } else if ([ext isEqualToString:@"v64"]) {
            for (NSUInteger i = 0; i < input.length; i += 2) {
                out[i] = in[i + 1];
                out[i + 1] = in[i];
            }
        } else {
            for (NSUInteger i = 0; i < input.length; i += 4) {
                out[i] = in[i + 3];
                out[i + 1] = in[i + 2];
                out[i + 2] = in[i + 1];
                out[i + 3] = in[i];
            }
        }

        if (![normalized writeToURL:destination options:NSDataWritingAtomic error:&error]) {
            NSLog(@"[DK64 iOS] Failed to import ROM %@: %@", source.lastPathComponent, error);
        } else {
            NSLog(@"[DK64 iOS] Imported ROM %@ as DK64.z64", source.lastPathComponent);
        }
        return;
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

    if (chdir(dk64Directory.fileSystemRepresentation) != 0) {
        NSLog(@"[DK64 iOS] Failed to set working directory to app data directory");
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
