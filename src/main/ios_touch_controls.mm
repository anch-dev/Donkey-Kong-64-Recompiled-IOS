// On-screen touch controller for iOS. Draws a native UIKit overlay in its OWN transparent UIWindow
// (above the SDL window, independent of SDL's view hierarchy) and drives an SDL virtual gamepad, so
// the game sees it as an ordinary controller using the default bindings (A=south, B=west,
// Z/R=triggers, C buttons=right stick, ...).
//
// Touches that do not land on a virtual control are NOT consumed: the overlay window's hit-test
// returns nil for them, so UIKit delivers them to the SDL window underneath, where SDL's built-in
// touch->mouse translation drives the RmlUi menus (tap = left click).
#include "ios_touch_controls.h"
#include "ios_log.h"

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <cmath>
#include <string>

namespace {

SDL_Joystick* g_pad = nullptr;
SDL_Window* g_sdl_window = nullptr;

bool g_mapping_added = false;

void create_virtual_pad() {
    if (g_pad != nullptr) {
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

    int index = -1;
    if (!g_mapping_added) {
        // Register an explicit SDL controller mapping for the virtual device (button/axis index == SDL enum
        // value) before the device is announced, so SDL reports it as a game controller.
        index = SDL_JoystickAttachVirtualEx(&desc);
        if (index < 0) {
            NSLog(@"[DK64 iOS] Virtual gamepad attach failed: %s", SDL_GetError());
            return;
        }
        char guid_string[64] = {};
        SDL_JoystickGetGUIDString(SDL_JoystickGetDeviceGUID(index), guid_string, sizeof(guid_string));
        std::string mapping = std::string(guid_string) +
            ",DK64 Touch Controls,"
            "a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,leftstick:b7,rightstick:b8,"
            "leftshoulder:b9,rightshoulder:b10,dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
            "leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,";
        SDL_GameControllerAddMapping(mapping.c_str());
        g_mapping_added = true;
        SDL_JoystickDetachVirtual(index);
    }

    index = SDL_JoystickAttachVirtualEx(&desc);
    if (index < 0) {
        NSLog(@"[DK64 iOS] Virtual gamepad (re)attach failed: %s", SDL_GetError());
        return;
    }

    g_pad = SDL_JoystickOpen(index);
    if (g_pad == nullptr) {
        NSLog(@"[DK64 iOS] Virtual gamepad open failed: %s", SDL_GetError());
        return;
    }

    SDL_JoystickSetVirtualAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERLEFT, -32768);
    SDL_JoystickSetVirtualAxis(g_pad, SDL_CONTROLLER_AXIS_TRIGGERRIGHT, -32768);
    DK64_LOG("TOUCH virtual gamepad attached (instance %d)", (int)SDL_JoystickInstanceID(g_pad));
}

void destroy_virtual_pad() {
    if (g_pad == nullptr) {
        return;
    }
    SDL_JoystickID instance = SDL_JoystickInstanceID(g_pad);
    SDL_JoystickClose(g_pad);
    g_pad = nullptr;
    for (int i = 0; i < SDL_NumJoysticks(); i++) {
        if (SDL_JoystickIsVirtual(i) && SDL_JoystickGetDeviceInstanceID(i) == instance) {
            SDL_JoystickDetachVirtual(i);
            break;
        }
    }
    DK64_LOG("TOUCH virtual gamepad detached");
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
// `pressed` is the logical state: what the game sees AND what is drawn. It follows the fingers but is held for at least
// kMinHoldSeconds so a very short tap cannot fall between two input polls of the game.
@property (nonatomic, assign) BOOL pressed;
@property (nonatomic, assign) NSInteger touchCount;     // fingers currently on this control
@property (nonatomic, assign) NSUInteger generation;    // invalidates a pending delayed release
@property (nonatomic, assign) CFTimeInterval pressedAt;
@property (nonatomic, strong) CALayer* container;
@property (nonatomic, strong) CAGradientLayer* gradient;
@property (nonatomic, strong) CAShapeLayer* shade;       // dark overlay shown while pressed
@property (nonatomic, strong) CAShapeLayer* outline;
@property (nonatomic, strong) CALayer* gloss;            // top highlight, hidden while pressed
@property (nonatomic, strong) CAGradientLayer* innerShadow;  // dark lip along the top edge, shown while pressed
@property (nonatomic, strong) CALayer* well;             // dark socket the button sinks into
@property (nonatomic, assign) BOOL visualRefreshPending;
@end

@implementation DK64Control
@end

// One record per active UITouch: what that finger is currently driving.
@interface DK64TouchRecord : NSObject
@property (nonatomic, strong) DK64Control* control;  // nil = not on a control right now (or driving the stick)
@property (nonatomic, assign) BOOL isStick;
@end

@implementation DK64TouchRecord
@end

static const CFTimeInterval kMinHoldSeconds = 0.040;  // ~one 30 Hz game frame: a tap shorter than a poll can otherwise be missed. Presses are never delayed.
static const CGFloat kHitSlop = 8.0;                  // forgiving press area around a button
static const CGFloat kHoldSlop = 26.0;                // a finger may drift this far before it leaves its button

@interface DK64TouchOverlayView : UIView
@end

@implementation DK64TouchOverlayView {
    NSMutableArray<DK64Control*>* _controls;
    NSMapTable<UITouch*, DK64TouchRecord*>* _records;
    UITouch* _stickTouch;
    CGPoint _stickCenter;
    CGPoint _stickRestCenter;
    CALayer* _stickRing;
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
        _records = [NSMapTable strongToStrongObjectsMapTable];
        self.exclusiveTouch = NO;
        _stickVector = CGPointZero;
    }
    return self;
}

static UIColor* DK64RGB(CGFloat r, CGFloat g, CGFloat b, CGFloat a = 1.0) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// DK64 look: N64 face-button colours, barrel-wood browns, banana gold and DK's red tie.
static void DK64Palette(DK64Action action, UIColor** light, UIColor** dark, UIColor** label) {
    switch (action) {
    case DK64ActionA:
        *light = DK64RGB(0.45, 0.68, 1.00); *dark = DK64RGB(0.12, 0.33, 0.85); *label = [UIColor whiteColor]; break;
    case DK64ActionB:
        *light = DK64RGB(0.45, 0.88, 0.40); *dark = DK64RGB(0.08, 0.55, 0.18); *label = [UIColor whiteColor]; break;
    case DK64ActionCUp:
    case DK64ActionCDown:
    case DK64ActionCLeft:
    case DK64ActionCRight:
        *light = DK64RGB(1.00, 0.93, 0.35); *dark = DK64RGB(0.95, 0.68, 0.05); *label = DK64RGB(0.30, 0.15, 0.02); break;
    case DK64ActionStart:
        *light = DK64RGB(1.00, 0.35, 0.28); *dark = DK64RGB(0.70, 0.07, 0.07); *label = [UIColor whiteColor]; break;
    case DK64ActionMenu:
    case DK64ActionZ:
    case DK64ActionL:
    case DK64ActionR:
    default:
        *light = DK64RGB(0.74, 0.46, 0.22); *dark = DK64RGB(0.40, 0.22, 0.08); *label = DK64RGB(1.00, 0.88, 0.30); break;
    }
}

static NSString* const kDK64FontName = @"MarkerFelt-Wide";

static CATextLayer* DK64MakeText(NSString* string, CGFloat fontSize, UIColor* color, CGRect frame, UIColor* shadow) {
    CATextLayer* text = [CATextLayer layer];
    text.string = string;
    text.font = (__bridge CFTypeRef)kDK64FontName;
    text.fontSize = fontSize;
    text.alignmentMode = kCAAlignmentCenter;
    text.foregroundColor = color.CGColor;
    text.contentsScale = UIScreen.mainScreen.scale;
    text.frame = frame;
    text.shadowColor = shadow.CGColor;
    text.shadowOpacity = 1.0;
    text.shadowRadius = 0;
    text.shadowOffset = CGSizeMake(0, 1.5);
    return text;
}

static const char* DK64ActionName(DK64Action action) {
    switch (action) {
    case DK64ActionA: return "A";
    case DK64ActionB: return "B";
    case DK64ActionZ: return "Z";
    case DK64ActionL: return "L";
    case DK64ActionR: return "R";
    case DK64ActionStart: return "START";
    case DK64ActionMenu: return "MENU";
    case DK64ActionCUp: return "C-UP";
    case DK64ActionCDown: return "C-DOWN";
    case DK64ActionCLeft: return "C-LEFT";
    case DK64ActionCRight: return "C-RIGHT";
    default: return "?";
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

    UIColor *light = nil, *dark = nil, *labelColor = nil;
    DK64Palette(action, &light, &dark, &labelColor);
    UIColor* outlineColor = DK64RGB(0.20, 0.10, 0.03);

    BOOL round = (action == DK64ActionA || action == DK64ActionB || action == DK64ActionCUp || action == DK64ActionCDown ||
                  action == DK64ActionCLeft || action == DK64ActionCRight);
    CGFloat w = size.width, h = size.height;
    CGRect local = CGRectMake(0, 0, w, h);
    CGFloat radius = round ? std::min(w, h) / 2 : h * 0.42;
    UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(local, 2, 2) cornerRadius:radius];

    // The socket: always visible behind the button, so a pressed (smaller, lower) button visibly sinks into it.
    CAShapeLayer* well = [CAShapeLayer layer];
    well.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(control.frame, -3, -3)
                                           cornerRadius:round ? std::min(w, h) / 2 + 3 : h * 0.42 + 3].CGPath;
    well.fillColor = [UIColor colorWithRed:0.08 green:0.04 blue:0.01 alpha:0.50].CGColor;
    well.strokeColor = [UIColor colorWithWhite:0.0 alpha:0.35].CGColor;
    well.lineWidth = 1.5;
    [self.layer addSublayer:well];

    CALayer* container = [CALayer layer];
    container.frame = control.frame;
    container.opacity = 0.80;
    container.shadowColor = [UIColor blackColor].CGColor;
    container.shadowOpacity = 0.5;
    container.shadowRadius = 3;
    container.shadowOffset = CGSizeMake(0, 2);

    CAGradientLayer* gradient = [CAGradientLayer layer];
    gradient.frame = local;
    gradient.colors = @[ (id)light.CGColor, (id)dark.CGColor ];
    gradient.startPoint = CGPointMake(0.5, 0.0);
    gradient.endPoint = CGPointMake(0.5, 1.0);
    CAShapeLayer* mask = [CAShapeLayer layer];
    mask.path = path.CGPath;
    gradient.mask = mask;
    [container addSublayer:gradient];

    CAShapeLayer* shade = [CAShapeLayer layer];
    shade.path = path.CGPath;
    shade.fillColor = [UIColor colorWithWhite:0.0 alpha:0.45].CGColor;
    shade.opacity = 0.0;
    [container addSublayer:shade];

    CAGradientLayer* innerShadow = [CAGradientLayer layer];
    innerShadow.frame = local;
    innerShadow.colors = @[ (id)[UIColor colorWithWhite:0.0 alpha:0.60].CGColor, (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor ];
    innerShadow.startPoint = CGPointMake(0.5, 0.0);
    innerShadow.endPoint = CGPointMake(0.5, 0.55);
    CAShapeLayer* innerMask = [CAShapeLayer layer];
    innerMask.path = path.CGPath;
    innerShadow.mask = innerMask;
    innerShadow.opacity = 0.0;
    [container addSublayer:innerShadow];

    CAShapeLayer* outline = [CAShapeLayer layer];
    outline.path = path.CGPath;
    outline.fillColor = nil;
    outline.strokeColor = outlineColor.CGColor;
    outline.lineWidth = 3.5;
    [container addSublayer:outline];

    CAShapeLayer* gloss = [CAShapeLayer layer];
    gloss.path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(w * 0.16, h * 0.09, w * 0.68, h * 0.30)
                                            cornerRadius:h * 0.15].CGPath;
    gloss.fillColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
    [container addSublayer:gloss];

    CGFloat fontSize = std::min(w, h) * (action == DK64ActionStart || action == DK64ActionMenu ? 0.44 : (round ? 0.55 : 0.52));
    CGRect textFrame = CGRectMake(0, (h - fontSize * 1.2) / 2, w, fontSize * 1.3);
    BOOL darkLabel = (action == DK64ActionCUp || action == DK64ActionCDown || action == DK64ActionCLeft || action == DK64ActionCRight);
    UIColor* textShadow = darkLabel ? DK64RGB(1.0, 0.95, 0.6, 0.6) : outlineColor;
    if (darkLabel) {
        // Draw the arrow as a vector triangle. The text glyphs U+25B6/U+25C0 render as colour emoji on iOS,
        // which made left/right look different from up/down.
        CGFloat t = std::min(w, h) * 0.30;
        CGPoint c = CGPointMake(w / 2, h / 2);
        UIBezierPath* tri = [UIBezierPath bezierPath];
        switch (action) {
        case DK64ActionCUp:
            [tri moveToPoint:CGPointMake(c.x, c.y - t)]; [tri addLineToPoint:CGPointMake(c.x + t, c.y + t * 0.8)]; [tri addLineToPoint:CGPointMake(c.x - t, c.y + t * 0.8)]; break;
        case DK64ActionCDown:
            [tri moveToPoint:CGPointMake(c.x, c.y + t)]; [tri addLineToPoint:CGPointMake(c.x + t, c.y - t * 0.8)]; [tri addLineToPoint:CGPointMake(c.x - t, c.y - t * 0.8)]; break;
        case DK64ActionCLeft:
            [tri moveToPoint:CGPointMake(c.x - t, c.y)]; [tri addLineToPoint:CGPointMake(c.x + t * 0.8, c.y - t)]; [tri addLineToPoint:CGPointMake(c.x + t * 0.8, c.y + t)]; break;
        default:
            [tri moveToPoint:CGPointMake(c.x + t, c.y)]; [tri addLineToPoint:CGPointMake(c.x - t * 0.8, c.y - t)]; [tri addLineToPoint:CGPointMake(c.x - t * 0.8, c.y + t)]; break;
        }
        [tri closePath];
        CAShapeLayer* arrow = [CAShapeLayer layer];
        arrow.path = tri.CGPath;
        arrow.fillColor = labelColor.CGColor;
        arrow.strokeColor = labelColor.CGColor;
        arrow.lineJoin = kCALineJoinRound;
        arrow.lineWidth = 3.0;
        arrow.shadowColor = DK64RGB(1.0, 0.95, 0.6).CGColor;
        arrow.shadowOpacity = 0.6;
        arrow.shadowRadius = 0;
        arrow.shadowOffset = CGSizeMake(0, 1.5);
        [container addSublayer:arrow];
    } else {
        [container addSublayer:DK64MakeText(DK64ActionLabel(action), fontSize, labelColor, textFrame, textShadow)];
    }

    [self.layer addSublayer:container];
    control.container = container;
    control.gradient = gradient;
    control.shade = shade;
    control.outline = outline;
    control.gloss = gloss;
    control.innerShadow = innerShadow;
    control.well = well;
    [_controls addObject:control];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    {
        static CGSize lastSize = CGSizeZero;
        if (!CGSizeEqualToSize(lastSize, self.bounds.size)) {
            if (lastSize.width > 0) [self resetAll];  // never carry a held control across a rotation
            lastSize = self.bounds.size;
        }
    }

    {
        static CGSize builtSize = CGSizeZero;
        static UIEdgeInsets builtInsets = UIEdgeInsetsZero;
        if (_controls.count > 0 && CGSizeEqualToSize(builtSize, self.bounds.size) && UIEdgeInsetsEqualToEdgeInsets(builtInsets, self.safeAreaInsets)) {
            return;  // nothing changed: rebuilding would recreate every control and drop any held press
        }
        builtSize = self.bounds.size;
        builtInsets = self.safeAreaInsets;
    }
    for (CALayer* layer in [self.layer.sublayers copy]) {
        [layer removeFromSuperlayer];
    }
    [_controls removeAllObjects];
    [_records removeAllObjects];
    _stickTouch = nil;

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
    _stickRestCenter = _stickCenter;
    UIColor* outlineColor = DK64RGB(0.20, 0.10, 0.03);
    _stickBase = [CAShapeLayer layer];
    _stickBase.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(_stickCenter.x - _stickRadius, _stickCenter.y - _stickRadius,
                                                                       _stickRadius * 2, _stickRadius * 2)].CGPath;
    _stickBase.fillColor = DK64RGB(0.40, 0.22, 0.08, 0.38).CGColor;   // barrel wood
    _stickBase.strokeColor = DK64RGB(1.00, 0.82, 0.15, 0.90).CGColor;  // banana gold rim
    _stickBase.lineWidth = 5.0;
    _stickBase.shadowColor = [UIColor blackColor].CGColor;
    _stickBase.shadowOpacity = 0.5;
    _stickBase.shadowRadius = 3;
    _stickBase.shadowOffset = CGSizeMake(0, 2);
    [self.layer addSublayer:_stickBase];

    CAShapeLayer* innerRing = [CAShapeLayer layer];
    _stickRing = innerRing;
    innerRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(_stickCenter.x - _stickRadius * 0.62, _stickCenter.y - _stickRadius * 0.62,
                                                                      _stickRadius * 1.24, _stickRadius * 1.24)].CGPath;
    innerRing.fillColor = nil;
    innerRing.strokeColor = outlineColor.CGColor;
    innerRing.lineWidth = 2.0;
    innerRing.opacity = 0.55;
    [self.layer addSublayer:innerRing];

    CGFloat thumbRadius = 28 * u;
    _stickThumb = [CAShapeLayer layer];
    _stickThumb.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-thumbRadius, -thumbRadius, thumbRadius * 2, thumbRadius * 2)].CGPath;
    _stickThumb.fillColor = DK64RGB(0.88, 0.14, 0.10, 0.92).CGColor;  // DK's red tie
    _stickThumb.strokeColor = outlineColor.CGColor;
    _stickThumb.lineWidth = 3.5;
    _stickThumb.shadowColor = [UIColor blackColor].CGColor;
    _stickThumb.shadowOpacity = 0.5;
    _stickThumb.shadowRadius = 3;
    _stickThumb.shadowOffset = CGSizeMake(0, 2);
    _stickThumb.position = _stickCenter;
    CGFloat dkSize = thumbRadius * 0.95;
    [_stickThumb addSublayer:DK64MakeText(@"DK", dkSize, DK64RGB(1.0, 0.86, 0.15), CGRectMake(-thumbRadius, -dkSize * 0.62, thumbRadius * 2, dkSize * 1.3), outlineColor)];
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
    static const CFTimeInterval kMinVisualSeconds = 0.11;  // visual only: input state is never held back by this
    CFTimeInterval now = CACurrentMediaTime();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (DK64Control* control in _controls) {
        CFTimeInterval visualRemaining = control.pressedAt + kMinVisualSeconds - now;
        BOOL showPressed = control.pressed || visualRemaining > 0.0;
        if (!control.pressed && visualRemaining > 0.0 && !control.visualRefreshPending) {
            // A tap shorter than ~7 frames would flash by unseen; keep drawing it pressed until the minimum has passed.
            control.visualRefreshPending = YES;
            __weak DK64TouchOverlayView* weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((visualRemaining + 0.005) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                control.visualRefreshPending = NO;
                [weakSelf refreshVisuals];
            });
        }
        CALayer* c = control.container;
        if (showPressed) {
            // Pushed into its socket: clearly smaller and lower, darker, top lip shadowed, highlight gone, outer shadow gone.
            c.transform = CATransform3DConcat(CATransform3DMakeScale(0.86, 0.86, 1.0), CATransform3DMakeTranslation(0, 4.0, 0));
            c.opacity = 0.92;
            c.shadowOpacity = 0.0;
            control.shade.opacity = 1.0;
            control.innerShadow.opacity = 1.0;
            control.gloss.opacity = 0.0;
            control.gradient.startPoint = CGPointMake(0.5, 1.0);
            control.gradient.endPoint = CGPointMake(0.5, 0.0);
            control.outline.lineWidth = 5.0;
            control.well.opacity = 1.0;
        } else {
            c.transform = CATransform3DIdentity;
            c.opacity = 0.80;
            c.shadowOpacity = 0.5;
            c.shadowRadius = 3.0;
            c.shadowOffset = CGSizeMake(0, 2.0);
            control.shade.opacity = 0.0;
            control.innerShadow.opacity = 0.0;
            control.gloss.opacity = 1.0;
            control.gradient.startPoint = CGPointMake(0.5, 0.0);
            control.gradient.endPoint = CGPointMake(0.5, 1.0);
            control.outline.lineWidth = 3.5;
            control.well.opacity = 0.7;
        }
    }
    _stickThumb.position = CGPointMake(_stickCenter.x + _stickVector.x * _stickRadius, _stickCenter.y + _stickVector.y * _stickRadius);
    [CATransaction commit];
}

- (DK64Control*)controlAtPoint:(CGPoint)point slop:(CGFloat)slop {
    DK64Control* best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (DK64Control* control in _controls) {
        if (!CGRectContainsPoint(CGRectInset(control.frame, -slop, -slop), point)) continue;
        CGFloat dx = point.x - CGRectGetMidX(control.frame);
        CGFloat dy = point.y - CGRectGetMidY(control.frame);
        CGFloat distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            bestDistance = distance;
            best = control;
        }
    }
    return best;
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
    // The overlay window is only shown during gameplay (see dk64_ios_touch_controls_set_gameplay), so it owns every
    // touch while visible: a thumb that lands slightly off a button still drives the controller instead of becoming a
    // stray mouse click. In menus the whole window is hidden and SDL receives touches directly.
    return self;
}

- (void)updateStickWithTouch:(UITouch*)touch {
    CGPoint p = [touch locationInView:self];
    CGFloat dx = (p.x - _stickCenter.x) / _stickRadius;
    CGFloat dy = (p.y - _stickCenter.y) / _stickRadius;
    CGFloat length = std::sqrt(dx * dx + dy * dy);
    if (length > 1.0) {
        dx /= length;
        dy /= length;
        length = 1.0;
    }
    // Small radial dead zone (rescaled so full deflection is still reachable) to avoid jitter around the centre.
    const CGFloat kDeadZone = 0.10;
    if (length < kDeadZone) {
        dx = dy = 0.0;
    } else {
        CGFloat scale = (length - kDeadZone) / (1.0 - kDeadZone) / length;
        dx *= scale;
        dy *= scale;
    }
    _stickVector = CGPointMake(dx, dy);
}

// Floating stick: the stick base re-centres under the finger that starts it, then returns when it lifts.
- (void)moveStickBaseTo:(CGPoint)center {
    _stickCenter = center;
    CGPoint delta = CGPointMake(center.x - _stickRestCenter.x, center.y - _stickRestCenter.y);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CATransform3D t = CATransform3DMakeTranslation(delta.x, delta.y, 0);
    _stickBase.transform = t;
    _stickRing.transform = t;
    [CATransaction commit];
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

    {
        static unsigned last_mask = 0;
        unsigned mask = (a << 0) | (b << 1) | (z << 2) | (l << 3) | (r << 4) | (start << 5) | (menu << 6) | (cUp << 7) | (cDown << 8) | (cLeft << 9) | (cRight << 10);
        if (mask != last_mask) {
            DK64_LOG("TOUCH buttons: A=%d B=%d Z=%d L=%d R=%d START=%d MENU=%d C(up/down/left/right)=%d%d%d%d stick=(%.2f,%.2f)", a, b, z, l, r, start, menu,
                     cUp, cDown, cLeft, cRight, _stickVector.x, _stickVector.y);
            last_mask = mask;
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

- (void)pressControl:(DK64Control*)control {
    control.generation++;  // cancels any delayed release still pending from a previous tap
    control.touchCount++;
    if (!control.pressed) {
        control.pressed = YES;
        control.pressedAt = CACurrentMediaTime();
    }
}

// Called when one finger leaves a control. The control is released only when its last finger is gone, and never before it
// has been down for kMinHoldSeconds (unless the touch was cancelled).
- (void)releaseControl:(DK64Control*)control immediately:(BOOL)immediately {
    if (control.touchCount > 0) control.touchCount--;
    if (control.touchCount > 0) return;
    CFTimeInterval remaining = kMinHoldSeconds - (CACurrentMediaTime() - control.pressedAt);
    if (immediately || remaining <= 0.0) {
        control.generation++;
        control.pressed = NO;
        return;
    }
    NSUInteger generation = ++control.generation;
    __weak DK64TouchOverlayView* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DK64TouchOverlayView* strongSelf = weakSelf;
        if (strongSelf == nil || control.generation != generation || control.touchCount > 0) return;
        control.pressed = NO;
        [strongSelf applyState];
    });
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        CGPoint p = [touch locationInView:self];
        DK64TouchRecord* record = [[DK64TouchRecord alloc] init];
        DK64Control* control = [self controlAtPoint:p slop:kHitSlop];
        if (control != nil) {
            record.control = control;
            [self pressControl:control];
        } else if (_stickTouch == nil && (p.x < self.bounds.size.width * 0.5 || [self pointInStickZone:p])) {
            record.isStick = YES;  // only one finger may own the stick
            _stickTouch = touch;
            if (![self pointInStickZone:p]) {
                CGFloat m = _stickRadius;
                [self moveStickBaseTo:CGPointMake(std::max(m, std::min(self.bounds.size.width - m, p.x)),
                                                  std::max(m, std::min(self.bounds.size.height - m, p.y)))];
            }
            [self updateStickWithTouch:touch];
        } else {
            // Nothing exactly under the finger: take the nearest button within a generous radius so a slightly
            // missed press still counts, instead of being swallowed.
            DK64Control* nearby = [self controlAtPoint:p slop:40.0];
            if (nearby == nil) continue;
            record.control = nearby;
            [self pressControl:nearby];
        }
        [_records setObject:record forKey:touch];
        DK64_LOG("TOUCH down %p -> %s at (%.0f,%.0f) fingersOnOverlay=%lu", (__bridge void*)touch,
                 record.isStick ? "STICK" : DK64ActionName(record.control.action), p.x, p.y, (unsigned long)_records.count);
    }
    [self applyState];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        DK64TouchRecord* record = [_records objectForKey:touch];
        if (record == nil) continue;
        CGPoint p = [touch locationInView:self];
        if (record.isStick) {
            [self updateStickWithTouch:touch];
            continue;
        }
        // Sliding between buttons: leave the current one once the finger drifts well outside it, and press whichever
        // button it moves onto. Other fingers are never affected.
        if (record.control != nil && !CGRectContainsPoint(CGRectInset(record.control.frame, -kHoldSlop, -kHoldSlop), p)) {
            [self releaseControl:record.control immediately:NO];
            record.control = nil;
        }
        if (record.control == nil) {
            DK64Control* entered = [self controlAtPoint:p slop:kHitSlop];
            if (entered != nil) {
                record.control = entered;
                [self pressControl:entered];
            }
        }
    }
    [self applyState];
}

- (void)endTouches:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled {
    for (UITouch* touch in touches) {
        DK64TouchRecord* record = [_records objectForKey:touch];
        if (record == nil) {
            DK64_LOG("TOUCH %s %p (no record: it was never assigned to a control)", cancelled ? "CANCELLED" : "up", (__bridge void*)touch);
            continue;
        }
        DK64_LOG("TOUCH %s %p <- %s phase=%ld fingersOnOverlay=%lu", cancelled ? "CANCELLED by the system" : "up", (__bridge void*)touch,
                 record.isStick ? "STICK" : DK64ActionName(record.control.action), (long)touch.phase, (unsigned long)_records.count);
        if (record.isStick) {
            _stickTouch = nil;
            _stickVector = CGPointZero;
            [self moveStickBaseTo:_stickRestCenter];
        } else if (record.control != nil) {
            [self releaseControl:record.control immediately:cancelled];
        }
        [_records removeObjectForKey:touch];
    }
    [self applyState];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self endTouches:touches cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self endTouches:touches cancelled:YES];
}

- (void)resetAll {
    DK64_LOG("TOUCH resetAll: dropping %lu active finger(s)", (unsigned long)_records.count);
    for (DK64Control* control in _controls) {
        control.generation++;
        control.touchCount = 0;
        control.pressed = NO;
    }
    [_records removeAllObjects];
    _stickTouch = nil;
    _stickVector = CGPointZero;
    [self moveStickBaseTo:_stickRestCenter];
    [self applyState];
}

@end

// Transparent window that only accepts touches on virtual controls.
@interface DK64OverlayWindow : UIWindow
@end

@implementation DK64OverlayWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    return [super hitTest:point withEvent:event];
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
static BOOL g_gameplay = NO;           // game running and no UI menu capturing input; otherwise the overlay is hidden
static BOOL g_suspended = NO;          // temporarily hidden (e.g. while the ROM file picker is up)
static BOOL g_observers_installed = NO;

static NSString* const kTouchControlsKey = @"dk64_touch_controls_enabled";

static void run_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static BOOL user_wants_touch_controls() {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:kTouchControlsKey] == nil ? YES : [defaults boolForKey:kTouchControlsKey];
}

static BOOL physical_controller_connected() {
    for (GCController* controller in [GCController controllers]) {
        if (controller.extendedGamepad != nil || controller.gamepad != nil) {
            return YES;
        }
    }
    return NO;
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
    window.hidden = YES;
    g_overlay_window = window;
    g_overlay = overlay;
    DK64_LOG("TOUCH overlay window created: frame=%s scale=%.1f scene=%s sdlWindow=%p", NSStringFromCGRect(window.frame).UTF8String,
             UIScreen.mainScreen.scale, scene.description.UTF8String, (__bridge void*)sdlUIWindow);
}

// Single place that decides whether the on-screen gamepad is active:
//   on  = user setting enabled AND no physical controller connected AND not temporarily suspended.
static void refresh_overlay_state() {
    if (g_sdl_window == nullptr) {
        return;
    }
    BOOL active = user_wants_touch_controls() && !physical_controller_connected();
    {
        static int last_active = -1, last_suspended = -1;
        if (last_active != (int)active || last_suspended != (int)g_suspended) {
            DK64_LOG("TOUCH overlay state: userWants=%d physicalController=%d active=%d suspended=%d", (int)user_wants_touch_controls(),
                     (int)physical_controller_connected(), (int)active, (int)g_suspended);
            last_active = active;
            last_suspended = g_suspended;
        }
    }

    if (active) {
        create_overlay_window();
        create_virtual_pad();
    } else {
        destroy_virtual_pad();
    }

    if (g_overlay_window != nil) {
        BOOL show = active && !g_suspended && g_gameplay;
        if (g_overlay_window.hidden == show) {
            g_overlay_window.hidden = !show;
        }
        if (!show) {
            [g_overlay resetAll];
        }
    }
}

static void install_observers() {
    if (g_observers_installed) {
        return;
    }
    g_observers_installed = YES;
    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];
    NSOperationQueue* main = [NSOperationQueue mainQueue];
    void (^refresh)(NSNotification*) = ^(NSNotification* note) { (void)note; refresh_overlay_state(); };
    [center addObserverForName:GCControllerDidConnectNotification object:nil queue:main usingBlock:refresh];
    [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:main usingBlock:refresh];
    // Fires when the on-screen gamepad switch changes in the iOS Settings app.
    [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:main usingBlock:refresh];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:refresh];
    void (^releaseAll)(NSNotification*) = ^(NSNotification* note) {
        (void)note;
        DK64_LOG("TOUCH lifecycle: releasing all virtual controls");
        [g_overlay resetAll];
    };
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:main usingBlock:releaseAll];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:releaseAll];
    [center addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification object:nil queue:main usingBlock:releaseAll];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:^{}];
}

extern "C" void dk64_ios_touch_controls_init(void* sdl_window) {
    if (sdl_window == nullptr) {
        return;
    }
    g_sdl_window = (SDL_Window*)sdl_window;
    run_on_main(^{
        install_observers();
        refresh_overlay_state();
    });
}

extern "C" void dk64_ios_touch_controls_set_visible(int visible) {
    // Kept for compatibility: visibility is now decided by refresh_overlay_state()
    // (user setting + physical controller presence), so just re-evaluate.
    (void)visible;
    run_on_main(^{ refresh_overlay_state(); });
}

extern "C" void dk64_ios_touch_controls_set_gameplay(int gameplay) {
    BOOL value = gameplay ? YES : NO;
    if (g_gameplay != value) {
        g_gameplay = value;
        DK64_LOG("TOUCH mode: %s", value ? "gameplay (virtual controller)" : "menu (touch -> mouse)");
        run_on_main(^{ refresh_overlay_state(); });  // UIKit work must happen on the main thread
    }
}

extern "C" void dk64_ios_touch_controls_set_suspended(int suspended) {
    run_on_main(^{
        g_suspended = suspended ? YES : NO;
        refresh_overlay_state();
    });
}

// Called regularly from the main-thread event loop. Retries creation if UIKit was not ready when the
// SDL window was created, and re-evaluates state in case a notification was missed.
extern "C" void dk64_ios_touch_controls_tick(void) {
    static unsigned counter = 0;
    if ((++counter % 120) != 0 || g_sdl_window == nullptr || ![NSThread isMainThread]) {
        return;
    }
    refresh_overlay_state();
}

extern "C" void* dk64_ios_ui_window(void) {
    if (g_sdl_window == nullptr) {
        return nullptr;
    }
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(g_sdl_window, &info)) {
        return nullptr;
    }
    return (__bridge void*)info.info.uikit.window;
}
