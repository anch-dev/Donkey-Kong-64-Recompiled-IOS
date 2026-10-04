// On-screen touch controller for iOS. Draws a native UIKit overlay in its OWN transparent UIWindow
// (above the SDL window, independent of SDL's view hierarchy) and drives an SDL virtual gamepad, so
// the game sees it as an ordinary controller using the default bindings (A=south, B=west,
// Z/R=triggers, C buttons=right stick, ...).
//
// Touches that do not land on a virtual control are NOT consumed: the overlay window's hit-test
// returns nil for them, so UIKit delivers them to the SDL window underneath, where SDL's built-in
// touch->mouse translation drives the RmlUi menus (tap = left click).
#include "ios_touch_controls.h"

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cmath>
#include <string>

namespace {

SDL_Joystick* g_pad = nullptr;
bool g_pad_failed = false;
SDL_Window* g_sdl_window = nullptr;

void create_virtual_pad() {
    if (g_pad != nullptr || g_pad_failed) {
        return;
    }

    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    desc.vendor_id = 0x4B44;
    desc.product_id = 0x0064;
    desc.name = "DK64 Touch Controls";

    int index = SDL_JoystickAttachVirtualEx(&desc);
    if (index < 0) {
        NSLog(@"[DK64 iOS] Virtual gamepad attach failed: %s", SDL_GetError());
        g_pad_failed = true;
        return;
    }

    // Register an explicit SDL controller mapping for the virtual device (button/axis index == SDL enum value),
    // then re-attach so SDL announces it as a game controller.
    char guid_string[64] = {};
    SDL_JoystickGetGUIDString(SDL_JoystickGetDeviceGUID(index), guid_string, sizeof(guid_string));
    std::string mapping = std::string(guid_string) +
        ",DK64 Touch Controls,"
        "a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,leftstick:b7,rightstick:b8,"
        "leftshoulder:b9,rightshoulder:b10,dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
        "leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,platform:iOS,";
    SDL_GameControllerAddMapping(mapping.c_str());

    SDL_JoystickDetachVirtual(index);
    index = SDL_JoystickAttachVirtualEx(&desc);
    if (index < 0) {
        NSLog(@"[DK64 iOS] Virtual gamepad re-attach failed: %s", SDL_GetError());
        g_pad_failed = true;
        return;
    }

    g_pad = SDL_JoystickOpen(index);
    if (g_pad == nullptr) {
        NSLog(@"[DK64 iOS] Virtual gamepad open failed: %s", SDL_GetError());
        g_pad_failed = true;
        return;
    }

    SDL_JoystickSetVirtualAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT, -32768);
    SDL_JoystickSetVirtualAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT, -32768);
}

void set_button(int button, bool down) {
    if (g_pad != nullptr) {
        SDL_JoystickSetVirtualButton(g_pad, button, down ? 1 : 0);
    }
}

void set_axis(int axis, int value) {
    if (g_pad != nullptr) {
        SDL_JoystickSetVirtualAxis(g_pad, axis, (Sint16)std::max(-32768, std::min(32767, value)));
    }
}

} // namespace

typedef NS_ENUM(NSInteger, DK64Action) {
    DK64ActionA,
    DK64ActionB,
    DK64ActionZ,
    DK64ActionL,
    DK64ActionR,
    DK64ActionStart,
    DK64ActionMenu,
    DK64ActionCUp,
    DK64ActionCDown,
    DK64ActionCLeft,
    DK64ActionCRight,
};

@interface DK64Control : NSObject
@property (nonatomic, assign) DK64Action action;
@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, strong) CAShapeLayer* shape;
@end

@implementation DK64Control
@end

@interface DK64TouchOverlayView : UIView
@end

@implementation DK64TouchOverlayView {
    NSMutableArray<DK64Control*>* _controls;
    NSMutableDictionary<NSValue*, id>* _assignments;
    CGPoint _stickCenter;
    CGFloat _stickRadius;
    CAShapeLayer* _stickBase;
    CAShapeLayer* _stickThumb;
    CGPoint _stickVector;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        self.opaque = NO;
        _controls = [NSMutableArray array];
        _assignments = [NSMutableDictionary dictionary];
        _stickVector = CGPointZero;
    }
    return self;
}

static UIColor* DK64ActionColor(DK64Action action) {
    switch (action) {
    case DK64ActionA: return [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:1.0];
    case DK64ActionB: return [UIColor colorWithRed:0.25 green:0.8 blue:0.35 alpha:1.0];
    case DK64ActionCUp:
    case DK64ActionCDown:
    case DK64ActionCLeft:
    case DK64ActionCRight: return [UIColor colorWithRed:1.0 green:0.85 blue:0.1 alpha:1.0];
    case DK64ActionStart: return [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0];
    default: return [UIColor whiteColor];
    }
}

static NSString* DK64ActionLabel(DK64Action action) {
    switch (action) {
    case DK64ActionA: return @"A";
    case DK64ActionB: return @"B";
    case DK64ActionZ: return @"Z";
    case DK64ActionL: return @"L";
    case DK64ActionR: return @"R";
    case DK64ActionStart: return @"START";
    case DK64ActionMenu: return @"MENU";
    case DK64ActionCUp: return @"\u25B2";
    case DK64ActionCDown: return @"\u25BC";
    case DK64ActionCLeft: return @"\u25C0";
    case DK64ActionCRight: return @"\u25B6";
    }
    return @"";
}

- (void)addControl:(DK64Action)action center:(CGPoint)center size:(CGSize)size {
    DK64Control* control = [[DK64Control alloc] init];
    control.action = action;
    control.frame = CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height);

    UIColor* color = DK64ActionColor(action);
    CAShapeLayer* shape = [CAShapeLayer layer];
    shape.frame = control.frame;
    shape.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                            cornerRadius:std::min(size.width, size.height) / 2].CGPath;
    shape.fillColor = [color colorWithAlphaComponent:0.18].CGColor;
    shape.strokeColor = [color colorWithAlphaComponent:0.75].CGColor;
    shape.lineWidth = 2.0;
    [self.layer addSublayer:shape];

    CATextLayer* text = [CATextLayer layer];
    CGFloat fontSize = std::min(size.width, size.height) * (action == DK64ActionStart || action == DK64ActionMenu ? 0.38 : 0.5);
    text.string = DK64ActionLabel(action);
    text.fontSize = fontSize;
    text.alignmentMode = kCAAlignmentCenter;
    text.foregroundColor = [UIColor colorWithWhite:1.0 alpha:0.9].CGColor;
    text.contentsScale = UIScreen.mainScreen.scale;
    text.frame = CGRectMake(0, (size.height - fontSize * 1.2) / 2, size.width, fontSize * 1.3);
    [shape addSublayer:text];

    control.shape = shape;
    [_controls addObject:control];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    for (CALayer* layer in [self.layer.sublayers copy]) {
        [layer removeFromSuperlayer];
    }
    [_controls removeAllObjects];

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat u = std::max(0.7, std::min(1.4, std::min(w, h) / 390.0));
    UIEdgeInsets insets = self.safeAreaInsets;
    CGFloat left = insets.left + 20 * u;
    CGFloat right = w - insets.right - 20 * u;
    CGFloat top = insets.top + 12 * u;
    CGFloat bottom = h - std::max(insets.bottom, 8.0) - 16 * u;

    // Left analog stick.
    _stickRadius = 62 * u;
    _stickCenter = CGPointMake(left + 72 * u, bottom - 78 * u);
    _stickBase = [CAShapeLayer layer];
    _stickBase.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(_stickCenter.x - _stickRadius, _stickCenter.y - _stickRadius,
                                                                       _stickRadius * 2, _stickRadius * 2)].CGPath;
    _stickBase.fillColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
    _stickBase.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    _stickBase.lineWidth = 2.0;
    [self.layer addSublayer:_stickBase];

    CGFloat thumbRadius = 26 * u;
    _stickThumb = [CAShapeLayer layer];
    _stickThumb.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-thumbRadius, -thumbRadius, thumbRadius * 2, thumbRadius * 2)].CGPath;
    _stickThumb.fillColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    _stickThumb.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.8].CGColor;
    _stickThumb.lineWidth = 2.0;
    _stickThumb.position = _stickCenter;
    [self.layer addSublayer:_stickThumb];

    // Face buttons (bottom right).
    [self addControl:DK64ActionA center:CGPointMake(right - 52 * u, bottom - 62 * u) size:CGSizeMake(80 * u, 80 * u)];
    [self addControl:DK64ActionB center:CGPointMake(right - 128 * u, bottom - 30 * u) size:CGSizeMake(64 * u, 64 * u)];

    // C buttons (right side, above the face buttons).
    CGPoint cc = CGPointMake(right - 86 * u, bottom - 180 * u);
    CGFloat cs = 46 * u;
    CGFloat cd = 44 * u;
    [self addControl:DK64ActionCUp center:CGPointMake(cc.x, cc.y - cd) size:CGSizeMake(cs, cs)];
    [self addControl:DK64ActionCDown center:CGPointMake(cc.x, cc.y + cd) size:CGSizeMake(cs, cs)];
    [self addControl:DK64ActionCLeft center:CGPointMake(cc.x - cd, cc.y) size:CGSizeMake(cs, cs)];
    [self addControl:DK64ActionCRight center:CGPointMake(cc.x + cd, cc.y) size:CGSizeMake(cs, cs)];

    // Shoulder buttons.
    [self addControl:DK64ActionZ center:CGPointMake(left + 42 * u, top + 22 * u) size:CGSizeMake(78 * u, 44 * u)];
    [self addControl:DK64ActionL center:CGPointMake(left + 130 * u, top + 22 * u) size:CGSizeMake(78 * u, 44 * u)];
    [self addControl:DK64ActionR center:CGPointMake(right - 42 * u, top + 22 * u) size:CGSizeMake(78 * u, 44 * u)];

    // Start / menu.
    [self addControl:DK64ActionStart center:CGPointMake(w / 2, bottom - 12 * u) size:CGSizeMake(88 * u, 34 * u)];
    [self addControl:DK64ActionMenu center:CGPointMake(w / 2, top + 17 * u) size:CGSizeMake(88 * u, 34 * u)];

    [self refreshVisuals];
}

- (void)refreshVisuals {
    for (DK64Control* control in _controls) {
        UIColor* color = DK64ActionColor(control.action);
        control.shape.fillColor = [color colorWithAlphaComponent:control.pressed ? 0.55 : 0.18].CGColor;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _stickThumb.position = CGPointMake(_stickCenter.x + _stickVector.x * _stickRadius, _stickCenter.y + _stickVector.y * _stickRadius);
    [CATransaction commit];
}

- (DK64Control*)controlAtPoint:(CGPoint)point {
    for (DK64Control* control in _controls) {
        if (CGRectContainsPoint(CGRectInset(control.frame, -8, -8), point)) {
            return control;
        }
    }
    return nil;
}

- (BOOL)pointInStickZone:(CGPoint)point {
    CGFloat dx = point.x - _stickCenter.x;
    CGFloat dy = point.y - _stickCenter.y;
    CGFloat zone = _stickRadius * 1.5;
    return (dx * dx + dy * dy) <= zone * zone;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (self.hidden || self.alpha < 0.01) {
        return nil;
    }
    // Only claim touches that land on a virtual control or the stick zone. Everything else returns
    // nil so UIKit passes the touch on to the SDL window below (SDL turns it into mouse input).
    if ([self controlAtPoint:point] != nil || [self pointInStickZone:point]) {
        return self;
    }
    return nil;
}

- (void)updateStickWithTouch:(UITouch*)touch {
    CGPoint p = [touch locationInView:self];
    CGFloat dx = (p.x - _stickCenter.x) / _stickRadius;
    CGFloat dy = (p.y - _stickCenter.y) / _stickRadius;
    CGFloat length = std::sqrt(dx * dx + dy * dy);
    if (length > 1.0) {
        dx /= length;
        dy /= length;
    }
    _stickVector = CGPointMake(dx, dy);
}

- (void)applyState {
    bool a = false, b = false, z = false, l = false, r = false, start = false, menu = false;
    bool cUp = false, cDown = false, cLeft = false, cRight = false;
    for (DK64Control* control in _controls) {
        bool down = control.pressed;
        switch (control.action) {
        case DK64ActionA: a = down; break;
        case DK64ActionB: b = down; break;
        case DK64ActionZ: z = down; break;
        case DK64ActionL: l = down; break;
        case DK64ActionR: r = down; break;
        case DK64ActionStart: start = down; break;
        case DK64ActionMenu: menu = down; break;
        case DK64ActionCUp: cUp = down; break;
        case DK64ActionCDown: cDown = down; break;
        case DK64ActionCLeft: cLeft = down; break;
        case DK64ActionCRight: cRight = down; break;
        }
    }

    set_button(SDL_CONTROLLER_BUTTON_A, a);
    set_button(SDL_CONTROLLER_BUTTON_X, b);                 // N64 B = west button (DK64 default binding; EAST is C-Right)
    set_button(SDL_CONTROLLER_BUTTON_RIGHTSTICK, l);        // N64 L = R3 (DK64 default binding; LEFTSHOULDER is C-Down)
    set_button(SDL_CONTROLLER_BUTTON_START, start);
    set_button(SDL_CONTROLLER_BUTTON_BACK, menu);           // opens the recomp config menu
    set_axis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, z ? 32767 : -32768);   // N64 Z
    set_axis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT, r ? 32767 : -32768);  // N64 R
    set_axis(SDL_CONTROLLER_AXIS_RIGHTX, ((cRight ? 1 : 0) - (cLeft ? 1 : 0)) * 32767);
    set_axis(SDL_CONTROLLER_AXIS_RIGHTY, ((cDown ? 1 : 0) - (cUp ? 1 : 0)) * 32767);
    set_axis(SDL_CONTROLLER_AXIS_LEFTX, (int)std::lround(_stickVector.x * 32767.0));
    set_axis(SDL_CONTROLLER_AXIS_LEFTY, (int)std::lround(_stickVector.y * 32767.0));
    [self refreshVisuals];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSValue* key = [NSValue valueWithNonretainedObject:touch];
        DK64Control* control = [self controlAtPoint:p];
        if (control != nil) {
            control.pressed = YES;
            _assignments[key] = control;
        } else if ([self pointInStickZone:p]) {
            _assignments[key] = @"stick";
            [self updateStickWithTouch:touch];
        }
    }
    [self applyState];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        id assigned = _assignments[[NSValue valueWithNonretainedObject:touch]];
        if ([assigned isKindOfClass:[NSString class]]) {
            NSString* kind = (NSString*)assigned;
            if ([kind isEqualToString:@"stick"]) {
                [self updateStickWithTouch:touch];
            }
        }
    }
    [self applyState];
}

- (void)releaseTouches:(NSSet<UITouch*>*)touches {
    for (UITouch* touch in touches) {
        NSValue* key = [NSValue valueWithNonretainedObject:touch];
        id assigned = _assignments[key];
        if ([assigned isKindOfClass:[DK64Control class]]) {
            ((DK64Control*)assigned).pressed = NO;
        } else if ([assigned isKindOfClass:[NSString class]]) {
            NSString* kind = (NSString*)assigned;
            if ([kind isEqualToString:@"stick"]) {
                _stickVector = CGPointZero;
            }
        }
        [_assignments removeObjectForKey:key];
    }
    [self applyState];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self releaseTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self releaseTouches:touches];
}

- (void)resetAll {
    for (DK64Control* control in _controls) {
        control.pressed = NO;
    }
    [_assignments removeAllObjects];
    _stickVector = CGPointZero;
    [self applyState];
}

@end

// Transparent window that only accepts touches on virtual controls.
@interface DK64OverlayWindow : UIWindow
@end

@implementation DK64OverlayWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    // Hitting the bare window means "no control here": let the SDL window below handle the touch.
    // (The overlay view is the root view and only returns itself when a control/stick was hit.)
    if (hit == self) {
        return nil;
    }
    return hit;
}
@end

@interface DK64OverlayViewController : UIViewController
@end

@implementation DK64OverlayViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
@end

static DK64OverlayWindow* g_overlay_window = nil;
static DK64TouchOverlayView* g_overlay = nil;

static void run_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static void create_overlay_window() {
    if (g_overlay_window != nil || g_sdl_window == nullptr) {
        return;
    }

    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(g_sdl_window, &info)) {
        NSLog(@"[DK64 iOS] Touch controls: SDL_GetWindowWMInfo failed: %s", SDL_GetError());
        return;
    }
    UIWindow* sdlUIWindow = info.info.uikit.window;

    DK64OverlayWindow* window = nil;
    UIWindowScene* scene = sdlUIWindow.windowScene;
    if (scene != nil) {
        window = [[DK64OverlayWindow alloc] initWithWindowScene:scene];
    } else {
        window = [[DK64OverlayWindow alloc] initWithFrame:(sdlUIWindow != nil ? sdlUIWindow.bounds : UIScreen.mainScreen.bounds)];
    }
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.windowLevel = UIWindowLevelNormal + 100;

    DK64OverlayViewController* controller = [[DK64OverlayViewController alloc] init];
    DK64TouchOverlayView* overlay = [[DK64TouchOverlayView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    controller.view = overlay;
    window.rootViewController = controller;

    // Do not make this the key window: SDL's window must stay key for keyboard/text input.
    window.hidden = NO;
    [overlay setNeedsLayout];
    [overlay layoutIfNeeded];

    g_overlay_window = window;
    g_overlay = overlay;
    NSLog(@"[DK64 iOS] Touch overlay window created: frame=%@ scale=%.1f scene=%@",
          NSStringFromCGRect(window.frame), UIScreen.mainScreen.scale, scene);
}

extern "C" void dk64_ios_touch_controls_init(void* sdl_window) {
    if (sdl_window == nullptr) {
        return;
    }
    g_sdl_window = (SDL_Window*)sdl_window;
    run_on_main(^{
        create_overlay_window();
        create_virtual_pad();
    });
}

extern "C" void dk64_ios_touch_controls_set_visible(int visible) {
    run_on_main(^{
        if (visible) {
            create_virtual_pad();
        }
        if (g_overlay_window == nil) {
            return;
        }
        g_overlay_window.hidden = visible ? NO : YES;
        if (!visible) {
            [g_overlay resetAll];
        }
    });
}

// Called regularly from the main-thread event loop. Retries creation if the UIKit scene was not
// ready when the SDL window was created, and keeps the overlay window visible.
extern "C" void dk64_ios_touch_controls_tick(void) {
    static unsigned counter = 0;
    if ((++counter % 120) != 0 || g_sdl_window == nullptr || ![NSThread isMainThread]) {
        return;
    }
    if (g_overlay_window == nil) {
        create_overlay_window();
    } else if (g_overlay_window.hidden) {
        g_overlay_window.hidden = NO;
    }
}
