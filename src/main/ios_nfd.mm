// iOS replacement for nativefiledialog-extended (which needs AppKit/GTK), built on UIDocumentPickerViewController.
//
// Design:
//  * The ROM picker is ASYNCHRONOUS (dk64_ios_pick_rom_async): it presents the picker and returns immediately; the delegate
//    callback imports the file and then invokes the completion. Nothing blocks or spins the main thread, which is what
//    starved UIKit/XPC callbacks (and the picker) in the previous synchronous implementation.
//  * The picker is presented from the REAL SDL window's root view controller (the same window the game renders into),
//    on the main thread, walking to the top-most presented controller. No extra windows are created.
//  * The picker runs in import mode: iOS (or LiveContainer's file-picker fix) hands back a local copy, and the import code
//    still opens it with security-scoped access to be safe.
//  * The legacy synchronous NFD_* entry points remain for any other caller, but only block when called OFF the main thread.
#include "nfd.h"
#include "ios_touch_controls.h"
#include "ios_log.h"
#import "ios_rom_import.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <cstdlib>
#include <cstring>

typedef void (*DK64PickDone)(void *context, int success, const char *path);

typedef void (^DK64PickCompletion)(NSArray<NSURL *> *urls, NSString *error);

@interface DK64PickerSession : NSObject <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) DK64PickCompletion completion;
@property (nonatomic, weak) UIDocumentPickerViewController *picker;
@property (nonatomic, assign) BOOL presented;
@property (nonatomic, assign) BOOL finished;
@end

// UIDocumentPickerViewController.delegate is weak, so the active session must be retained here.
static DK64PickerSession *g_session = nil;

static UIWindow *DK64SDLWindow() { return (__bridge UIWindow *)dk64_ios_ui_window(); }

static UIViewController *DK64TopViewController(UIViewController *root) {
    UIViewController *top = root;
    while (top.presentedViewController != nil && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

static void DK64FinishSession(DK64PickerSession *session, NSArray<NSURL *> *urls, NSString *error) {
    if (session.finished) return;
    session.finished = YES;
    if (g_session == session) g_session = nil;
    dk64_ios_touch_controls_set_suspended(0);
    DK64PickCompletion completion = session.completion;
    session.completion = nil;
    if (completion) completion(urls, error);
}

@implementation DK64PickerSession
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    DK64_LOG("PICKER delegate: picked %lu item(s), first=%s", (unsigned long)urls.count, urls.firstObject.path.UTF8String);
    DK64FinishSession(self, urls, nil);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    DK64_LOG("PICKER delegate: cancelled by user");
    DK64FinishSession(self, nil, nil);
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    DK64_LOG("PICKER dismissed by swipe");
    DK64FinishSession(self, nil, nil);
}
@end

// Must run on the main thread.
static void DK64PresentPicker(BOOL multiple, int attempt, DK64PickCompletion completion) {
    if (g_session != nil) {
        DK64_LOG("PICKER request ignored: a picker is already active");
        completion(nil, nil);
        return;
    }

    UIWindow *sdlWindow = DK64SDLWindow();
    UIViewController *root = sdlWindow.rootViewController;
    UIWindowScene *scene = sdlWindow.windowScene;
    UIViewController *top = root != nil ? DK64TopViewController(root) : nil;

    // The SDL window may not be fully set up yet, or be mid-transition (scene inactive/launching, a controller being
    // presented or dismissed). Retry briefly instead of presenting into a half-ready hierarchy.
    BOOL notReady = root == nil || top.isBeingPresented || top.isBeingDismissed || top.view.window == nil ||
                    (scene != nil && scene.activationState == UISceneActivationStateUnattached);
    if (notReady && attempt < 30) {
        DK64_LOG("PICKER waiting for UI (attempt %d): window=%p root=%p top=%p beingPresented=%d beingDismissed=%d inWindow=%d", attempt,
                 (__bridge void *)sdlWindow, (__bridge void *)root, (__bridge void *)top, (int)top.isBeingPresented, (int)top.isBeingDismissed,
                 (int)(top.view.window != nil));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DK64PresentPicker(multiple, attempt + 1, completion);
        });
        return;
    }
    if (top == nil) {
        DK64_LOG("PICKER cannot present: SDL window has no root view controller");
        completion(nil, @"The file picker could not be shown (no active window).");
        return;
    }

    DK64_LOG("PICKER presenting from %s (scene state=%ld, window=%p, presented chain depth ok)", NSStringFromClass([top class]).UTF8String,
             (long)scene.activationState, (__bridge void *)sdlWindow);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // "public.item" covers .z64/.v64/.n64, which have no registered type. Import mode hands us a private local copy.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.item", @"public.data" ] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.allowsMultipleSelection = multiple;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        picker.modalPresentationStyle = UIModalPresentationFullScreen;
    }  // iPad keeps the system's default sheet style, which UIDocumentPickerViewController sizes itself

    DK64PickerSession *session = [[DK64PickerSession alloc] init];
    session.completion = completion;
    session.picker = picker;
    picker.delegate = session;
    picker.presentationController.delegate = session;
    g_session = session;

    // The on-screen gamepad lives in its own window above SDL's; hide it while the picker is up.
    dk64_ios_touch_controls_set_suspended(1);

    [top presentViewController:picker
                      animated:YES
                    completion:^{
                        session.presented = YES;
                        DK64_LOG("PICKER presented on screen");
                    }];

    // Watchdog: if UIKit never presents it, report instead of leaving the game with a hidden overlay and no feedback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!session.finished && !session.presented) {
            DK64_LOG("PICKER never appeared within 20s (scene state=%ld, presenting=%p)", (long)scene.activationState,
                     (__bridge void *)picker.presentingViewController);
            DK64FinishSession(session, nil, @"The system file picker did not open. If you are running inside LiveContainer, enable "
                                            @"\"Fix File Picker\" in this app's LiveContainer settings, or place the ROM in the "
                                            @"app's Documents folder.");
        }
    });
}

static void DK64ShowAlert(NSString *title, NSString *message) {
    UIWindow *sdlWindow = DK64SDLWindow();
    UIViewController *top = sdlWindow.rootViewController != nil ? DK64TopViewController(sdlWindow.rootViewController) : nil;
    if (top == nil) {
        DK64_LOG("ALERT (no UI): %s - %s", title.UTF8String, message.UTF8String);
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Picker-created temp copies live in our tmp/Inbox; remove them once imported. Never touch user files elsewhere.
static void DK64DiscardPickerCopy(NSURL *url) {
    NSString *path = url.path;
    if ([path hasPrefix:NSTemporaryDirectory()] || [path containsString:@"/tmp/"] || [path containsString:@"/Inbox/"]) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
}

// Asynchronous ROM picker used by the launcher. `done` is always called exactly once, on the main thread.
extern "C" void dk64_ios_pick_rom_async(DK64PickDone done, void *context) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DK64PresentPicker(NO, 0, ^(NSArray<NSURL *> *urls, NSString *error) {
            if (error != nil) {
                DK64ShowAlert(@"Select ROM", error);
                done(context, 0, nullptr);
                return;
            }
            NSURL *picked = urls.firstObject;
            if (picked == nil) {  // cancelled
                done(context, 0, nullptr);
                return;
            }
            NSString *staged = [dk64_rom_staging_directory() stringByAppendingPathComponent:@"DK64.z64"];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *detail = nil;
                DK64RomImportStatus status = dk64_import_rom(picked, staged, &detail);
                dispatch_async(dispatch_get_main_queue(), ^{
                    DK64DiscardPickerCopy(picked);
                    if (status != DK64RomImportOK) {
                        NSString *message = dk64_rom_status_message(status);
                        if (detail.length > 0) message = [message stringByAppendingFormat:@"\n\n(%@)", detail];
                        DK64ShowAlert(@"Select ROM", message);
                        done(context, 0, nullptr);
                        return;
                    }
                    // Hand the local, app-controlled copy to the game's loader (librecomp validates the hash/version and
                    // stores its own persistent copy), then drop the staging file.
                    done(context, 1, staged.fileSystemRepresentation);
                    [[NSFileManager defaultManager] removeItemAtPath:staged error:nil];
                });
            });
        });
    });
}

// ---- Legacy synchronous NFD API ----------------------------------------------------------------------------------

nfdresult_t NFD_Init(void) { return NFD_OKAY; }
void NFD_Quit(void) {}
void NFD_FreePathN(nfdnchar_t *filePath) { free(filePath); }

static NSArray<NSURL *> *DK64PickBlocking(BOOL multiple) {
    if ([NSThread isMainThread]) {
        DK64_LOG("NFD: synchronous dialog requested on the main thread; refusing (use dk64_ios_pick_rom_async)");
        return nil;
    }
    __block NSArray<NSURL *> *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        DK64PresentPicker(multiple, 0, ^(NSArray<NSURL *> *urls, NSString *error) {
            result = urls;
            dispatch_semaphore_signal(done);
        });
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

nfdresult_t NFD_OpenDialogN(nfdnchar_t **outPath, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    @autoreleasepool {
        NSArray<NSURL *> *urls = DK64PickBlocking(NO);
        if (urls.count == 0) return NFD_CANCEL;
        *outPath = strdup(urls[0].path.UTF8String);
        return NFD_OKAY;
    }
}

nfdresult_t NFD_OpenDialogMultipleN(const nfdpathset_t **outPaths, const nfdnfilteritem_t *, nfdfiltersize_t, const nfdnchar_t *) {
    @autoreleasepool {
        NSArray<NSURL *> *urls = DK64PickBlocking(YES);
        if (urls.count == 0) return NFD_CANCEL;
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
    if (index >= urls.count) return NFD_ERROR;
    *outPath = strdup(urls[index].path.UTF8String);
    return NFD_OKAY;
}

void NFD_PathSet_Free(const nfdpathset_t *pathSet) { CFRelease((CFTypeRef)pathSet); }
