// iOS replacement for nativefiledialog-extended (which needs AppKit/GTK).
// Implements the NFD calls DK64 Recompiled uses on top of UIDocumentPickerViewController.
// The picker runs in "import" mode, so iOS hands us a temporary copy of the chosen file.
#include "nfd.h"
#include "ios_touch_controls.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdlib>
#include <cstring>

@interface DK64PickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSURL *> *urls;
@property (nonatomic, assign) BOOL done;
@end

@implementation DK64PickerDelegate
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    self.urls = urls;
    self.done = YES;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.urls = nil;
    self.done = YES;
}
@end

// Hosts the picker in a window we own. Reusing "whichever window is key" breaks when the app runs inside a
// container such as LiveContainer (the key window can belong to the host app) or when our own pass-through
// overlay window is on top, so we present from a dedicated, top-level window attached to SDL's scene.
@interface DK64PickerHostViewController : UIViewController
@end

@implementation DK64PickerHostViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static UIWindow *g_picker_window = nil;

static UIWindow *dk64MakePickerWindow(UIWindow *sdlWindow) {
    UIWindow *window = nil;
    UIWindowScene *scene = sdlWindow.windowScene;
    if (scene == nil) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }
    if (scene != nil) {
        window = [[UIWindow alloc] initWithWindowScene:scene];
    } else {
        window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }
    window.backgroundColor = [UIColor clearColor];
    window.windowLevel = UIWindowLevelAlert + 200;
    DK64PickerHostViewController *controller = [[DK64PickerHostViewController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    window.rootViewController = controller;
    [window makeKeyAndVisible];
    return window;
}

// Fallback when the system picker cannot be shown: use a ROM the user already placed in the app's Documents
// folder (visible in the Files app because UIFileSharingEnabled is on).
static NSURL *dk64FindRomInDocuments() {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (documents == nil) {
        return nil;
    }
    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:documents
                                includingPropertiesForKeys:@[ NSURLFileSizeKey ]
                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                     error:nil];
    for (NSURL *file in files) {
        NSString *ext = file.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"z64"] && ![ext isEqualToString:@"v64"] && ![ext isEqualToString:@"n64"]) {
            continue;
        }
        NSNumber *size = nil;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.unsignedLongLongValue == 33554432ULL) {
            return file;
        }
    }
    return nil;
}

static NSArray<NSURL *> *dk64PickDocuments(BOOL multiple) {
    if (![NSThread isMainThread]) {
        __block NSArray<NSURL *> *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = dk64PickDocuments(multiple);
        });
        return result;
    }

    UIWindow *sdlWindow = (__bridge UIWindow *)dk64_ios_ui_window();
    UIWindow *host = dk64MakePickerWindow(sdlWindow);
    g_picker_window = host;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // "public.item" covers .z64/.v64/.n64, which have no registered type. Import mode hands us a private copy.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item", @"public.data" ] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.allowsMultipleSelection = multiple;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;

    DK64PickerDelegate *delegate = [[DK64PickerDelegate alloc] init];
    picker.delegate = delegate;
    dk64_ios_touch_controls_set_suspended(1);

    __block BOOL shown = NO;
    [host.rootViewController presentViewController:picker animated:YES completion:^{ shown = YES; }];

    // Called on the main thread: keep servicing the run loop until the picker finishes.
    NSDate *start = [NSDate date];
    BOOL failed = NO;
    while (!delegate.done) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        if (!shown && -[start timeIntervalSinceNow] > 8.0) {
            NSLog(@"[DK64 iOS] File picker never appeared; giving up");
            failed = YES;
            break;
        }
        if (shown && picker.presentingViewController == nil) {
            break;  // dismissed without a delegate callback
        }
    }

    if (picker.presentingViewController != nil) {
        [picker dismissViewControllerAnimated:NO completion:nil];
    }
    host.hidden = YES;
    g_picker_window = nil;
    if (sdlWindow != nil) {
        [sdlWindow makeKeyWindow];
    }
    dk64_ios_touch_controls_set_suspended(0);

    if (delegate.urls.count > 0) {
        return delegate.urls;
    }
    if (failed) {
        NSURL *fallback = dk64FindRomInDocuments();
        if (fallback != nil) {
            NSLog(@"[DK64 iOS] Using ROM from Documents: %@", fallback.lastPathComponent);
            return @[ fallback ];
        }
    }
    return nil;
}

nfdresult_t NFD_Init(void) {
    return NFD_OKAY;
}

void NFD_Quit(void) {
}

void NFD_FreePathN(nfdnchar_t *filePath) {
    free(filePath);
}

nfdresult_t NFD_OpenDialogN(nfdnchar_t **outPath, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    @autoreleasepool {
        NSArray<NSURL *> *urls = dk64PickDocuments(NO);
        if (urls.count == 0) {
            return NFD_CANCEL;
        }
        *outPath = strdup(urls[0].path.UTF8String);
        return NFD_OKAY;
    }
}

nfdresult_t NFD_OpenDialogMultipleN(const nfdpathset_t **outPaths, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    @autoreleasepool {
        NSArray<NSURL *> *urls = dk64PickDocuments(YES);
        if (urls.count == 0) {
            return NFD_CANCEL;
        }
        *outPaths = (const nfdpathset_t *)CFBridgingRetain(urls);
        return NFD_OKAY;
    }
}

nfdresult_t NFD_PathSet_GetCount(const nfdpathset_t *pathSet, nfdpathsetsize_t *count) {
    NSArray<NSURL *> *urls = (__bridge NSArray<NSURL *> *)pathSet;
    *count = (nfdpathsetsize_t)urls.count;
    return NFD_OKAY;
}

nfdresult_t NFD_PathSet_GetPathN(const nfdpathset_t *pathSet, nfdpathsetsize_t index, nfdnchar_t **outPath) {
    NSArray<NSURL *> *urls = (__bridge NSArray<NSURL *> *)pathSet;
    if (index >= urls.count) {
        return NFD_ERROR;
    }
    *outPath = strdup(urls[index].path.UTF8String);
    return NFD_OKAY;
}

void NFD_PathSet_Free(const nfdpathset_t *pathSet) {
    CFRelease((CFTypeRef)pathSet);
}
