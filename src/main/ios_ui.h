#pragma once
// Small UIKit helpers shared by the iOS file features (Objective-C++ only). Implemented in ios_nfd.mm.
#import <UIKit/UIKit.h>

// Top-most view controller of the SDL window, or nil if the UI is not up yet. Main thread only.
UIViewController *dk64_ios_top_view_controller(void);

// Shows a simple OK alert over the SDL window. Main thread only.
void dk64_ios_show_alert(NSString *title, NSString *message);

// Presents the system file picker (import mode) for a single file. `completion` runs once on the main thread with a
// local copy of the picked file, or url == nil if cancelled (error != nil if the picker could not be shown).
void dk64_ios_pick_file(void (^completion)(NSURL *url, NSString *error));

// Deletes a picker-created temporary copy (never touches the user's original file).
void dk64_ios_discard_picker_copy(NSURL *url);
