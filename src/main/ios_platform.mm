#include "ios_platform.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>

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
