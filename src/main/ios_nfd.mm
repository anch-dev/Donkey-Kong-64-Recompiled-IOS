// iOS replacement for nativefiledialog-extended (which needs AppKit/GTK).
// Implements the NFD calls DK64 Recompiled uses on top of UIDocumentPickerViewController.
// The picker runs in "import" mode, so iOS hands us a temporary copy of the chosen file.
#include "nfd.h"

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

static UIViewController *dk64TopViewController() {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window == nil) {
            window = ((UIWindowScene *)scene).windows.firstObject;
        }
        if (window != nil) {
            break;
        }
    }

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static NSArray<NSURL *> *dk64PickDocuments(BOOL multiple) {
    if (![NSThread isMainThread]) {
        __block NSArray<NSURL *> *result = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = dk64PickDocuments(multiple);
        });
        return result;
    }

    UIViewController *presenter = dk64TopViewController();
    if (presenter == nil) {
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.data" ] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.allowsMultipleSelection = multiple;

    DK64PickerDelegate *delegate = [[DK64PickerDelegate alloc] init];
    picker.delegate = delegate;
    [presenter presentViewController:picker animated:YES completion:nil];

    // Called on the main thread: keep servicing it until the picker finishes.
    while (!delegate.done) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return delegate.urls;
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
