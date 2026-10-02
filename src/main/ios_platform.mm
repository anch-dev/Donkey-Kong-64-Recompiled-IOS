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
