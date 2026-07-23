// sm64_vision_settings.m — the "Vision Pro 3D" settings table.
//
// Ported from vkQuake-ios ios/shell/ios_settings.m's "Vision Pro 3D" section,
// which the charter names as the ready-made spec. Hosted in a SwiftUI .sheet
// (SM64VisionApp.swift), NOT presented as a UIKit modal: a UIKit modal silently
// FAILS over an open ImmersiveSpace (guide §2.7).
//
// Every panel/stereo slider applies LIVE while dragging — they are plain C state
// reads in the immersive loop and the matrix path, so there is nothing to batch
// and instant feedback is the whole point of tuning a panel you are looking at.
//
// WHAT WAS PORTED, AND WHAT WAS JUDGED NOT TO APPLY (charter: "say what you
// skipped and why"):
//   - "Crosshair Distance" -> renamed "Focus Distance". Same quantity (the
//     zero-parallax convergence plane), but Quake's name is literal: it is where
//     the aimpoint sits. SM64 has no crosshair, and naming a comfort control
//     after a UI element the game does not have would be actively misleading.
//   - "FPS on Panel" -> SKIPPED. It exists in vkQuake because its FPS readout is
//     a console/scr feature with no menu. coopdx already owns an FPS counter in
//     its own DJUI options menu; adding a second control for the same state
//     would be two sources of truth for one setting (and the DJUI menu renders
//     ON the panel in 3D anyway, so it is reachable).
//   - "Stereo Depth" -> kept, but presented as a PERCENTAGE of the default
//     rather than vkQuake's raw engine units. The underlying value is still
//     world units; a raw "6.5" means nothing to a player, and the charter
//     explicitly specifies "% of default".

#import "sm64_vision_host.h"

#ifdef SM64_VISION_3D

#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, SM64RowType) {
    SM64_ROW_SLIDER,
    SM64_ROW_SWITCH,
    SM64_ROW_SEG,
    SM64_ROW_BUTTON,
    SM64_ROW_INFO,
};

@interface SM64Row : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) SM64RowType type;
@property (nonatomic) float mn, mx, def;
@end
@implementation SM64Row
@end

static SM64Row *mkrow(NSString *title, NSString *key, SM64RowType type, float mn, float mx, float def) {
    SM64Row *r = [SM64Row new];
    r.title = title; r.key = key; r.type = type;
    r.mn = mn; r.mx = mx; r.def = def;
    return r;
}

static void tag_ctl(UIView *v, SM64Row *r) {
    objc_setAssociatedObject(v, "sm64_row", r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static SM64Row *ctl_row(UIView *v) {
    return objc_getAssociatedObject(v, "sm64_row");
}

static BOOL sm64_use_feet(void) {
    return sm64_3d_setting_f("units", SM64_DEF_UNITS) > 0.5f;
}

// Human-readable value text, honouring the m/ft toggle.
static NSString *sm64_value_text(NSString *key, float v) {
    if ([key isEqualToString:@"dim"]) {
        // Surroundings Dimming is a 0..100% control.
        return [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
    }
    if ([key isEqualToString:@"sep"]) {
        // % of default: the control the charter specifies.
        return [NSString stringWithFormat:@"%.0f%%", (v / SM64_DEF_SEP) * 100.0f];
    }
    if ([key isEqualToString:@"conv"]) {
        // World units -> metres. 1 SM64 unit ~= 1 cm (Mario is ~160 units tall
        // and ~1.5 m), so the convergence plane has a real physical reading.
        float metres = v / 100.0f;
        return sm64_use_feet() ? [NSString stringWithFormat:@"%.0f ft", metres * 3.28084f]
                               : [NSString stringWithFormat:@"%.1f m", metres];
    }
    if ([key isEqualToString:@"halfW"] || [key isEqualToString:@"halfH"]) {
        // Sliders hold HALF-extents; show the user the full panel size.
        float full = v * 2.0f;
        return sm64_use_feet() ? [NSString stringWithFormat:@"%.1f ft", full * 3.28084f]
                               : [NSString stringWithFormat:@"%.2f m", full];
    }
    if ([key isEqualToString:@"dist"] || [key isEqualToString:@"posH"]) {
        return sm64_use_feet() ? [NSString stringWithFormat:@"%.1f ft", v * 3.28084f]
                               : [NSString stringWithFormat:@"%.2f m", v];
    }
    return [NSString stringWithFormat:@"%.2f", v];
}

@interface SM64SettingsVC : UITableViewController
@end

// Weak handle to the live settings table so the SwiftUI header's Reset button
// (bridged via SM64_ResetVision3D) can reset AND reload the visible sliders.
// Weak: a dismissed sheet must not be retained, and a stale pointer becomes nil.
static __weak SM64SettingsVC *g_settingsVC = nil;

@implementation SM64SettingsVC {
    NSArray<NSArray<SM64Row *> *> *_rows;
    NSArray<NSString *> *_sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    g_settingsVC = self;
    _sections = @[ @"Vision Pro 3D" ];
    _rows = @[ @[
        mkrow(@"Screen Distance", @"dist", SM64_ROW_SLIDER, 1.0, 8.0, SM64_DEF_DIST),
        // Item 2: ranges WIDENED so the panel can go ultrawide / ultratall (the
        // engine re-renders at the new aspect, so this reshapes the FILLED image).
        mkrow(@"Screen Width", @"halfW", SM64_ROW_SLIDER, 0.4, 8.0, SM64_DEF_HALFW),
        mkrow(@"Screen Height", @"halfH", SM64_ROW_SLIDER, 0.3, 6.0, SM64_DEF_HALFH),
        mkrow(@"Screen Position Height", @"posH", SM64_ROW_SLIDER, -1.5, 10.0, SM64_DEF_POSH),
        // Rescale 2026-07-23 (user: "it doesn't go high enough"): default 18->27,
        // MAX 36->54. The % readout is v/SM64_DEF_SEP*100, so re-centering the
        // denominator on the new 27 default keeps the SLIDER looking identical
        // (0-200%, default 100%) while every % is 1.5x the old separation and the
        // top is 1.5x deeper. The setter clamps sep<=60 so 54 passes (gfx_pc.c
        // sm64_gfx_set_3d_params, raised from 40 in gen-patch-0011).
        mkrow(@"Stereo Depth", @"sep", SM64_ROW_SLIDER, 0.0, 54.0, SM64_DEF_SEP),  // max 54 = 200% of the new 27.0 default
        // Item 6: Focus Distance "Auto" derives the convergence from the panel
        // size (on by default). When on, the manual slider below is disabled and
        // shows the derived value; turn Auto off to set it by hand.
        mkrow(@"Focus Distance: Auto", @"convAuto", SM64_ROW_SWITCH, 0, 1, SM64_DEF_CONVAUTO),
        mkrow(@"Focus Distance", @"conv", SM64_ROW_SLIDER, 200.0, 3000.0, SM64_DEF_CONV),
        // Item 5: HUD Depth slider REMOVED (it only reached the ortho HUD, not the
        // Lakitu dialog boxes; default is now 0 = flush on panel = original).
        mkrow(@"Surroundings Dimming", @"dim", SM64_ROW_SLIDER, 0.0, 1.0, SM64_DEF_DIM),
        mkrow(@"Panel Width", @"infoW", SM64_ROW_INFO, 0, 0, 0),
        mkrow(@"Panel Height", @"infoH", SM64_ROW_INFO, 0, 0, 0),
        mkrow(@"Aspect Ratio", @"infoAspect", SM64_ROW_INFO, 0, 0, 0),
        mkrow(@"Units", @"units", SM64_ROW_SEG, 0, 1, SM64_DEF_UNITS),
        mkrow(@"Recenter Screen", @"recenter", SM64_ROW_BUTTON, 0, 0, 0),
    ] ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _sections.count; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _rows[s].count; }

// Custom header views get a COMPRESSED height without an explicit delegate,
// which shoves the title up under the sheet's own Settings bar.
- (CGFloat)tableView:(UITableView *)t heightForHeaderInSection:(NSInteger)s { return 44.0; }

// The "Vision Pro 3D" section title. Reset now lives in the SwiftUI sheet header
// beside Done (2026-07-23, SM64_ResetVision3D), so the header carries the label
// only — no trailing button to gaze-pinch under the sheet bar.
- (UIView *)tableView:(UITableView *)t viewForHeaderInSection:(NSInteger)s {
    UIView *hv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, t.bounds.size.width, 44)];
    UILabel *l = [UILabel new];
    l.text = _sections[s];
    l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    l.textColor = UIColor.labelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [hv addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.leadingAnchor constraintEqualToAnchor:hv.leadingAnchor constant:20],
        [l.bottomAnchor constraintEqualToAnchor:hv.bottomAnchor constant:-6],
    ]];
    return hv;
}

- (void)resetVision3D {
    for (NSString *k in @[ @"dist", @"halfW", @"halfH", @"posH", @"sep", @"conv", @"convAuto", @"dim" ]) {
        [NSUserDefaults.standardUserDefaults
            removeObjectForKey:[@"sm64vp3d." stringByAppendingString:k]];
    }
    sm64_3d_apply_settings();
    [self.tableView reloadData];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    SM64Row *r = _rows[ip.section][ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                reuseIdentifier:nil];
    c.textLabel.text = r.title;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    float v = sm64_3d_setting_f(r.key.UTF8String, r.def);

    if (r.type == SM64_ROW_BUTTON) {
        c.textLabel.textColor = c.tintColor;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (r.type == SM64_ROW_SEG) {
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[ @"m", @"ft" ]];
        seg.selectedSegmentIndex = v > 0.5f ? 1 : 0;
        tag_ctl(seg, r);
        [seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = seg;
        return c;
    }
    if (r.type == SM64_ROW_INFO) {
        // Read-only feedback: the live per-eye render target and its aspect.
        // Reports the ACTUAL texture the engine is rendering, not what we asked
        // for — the same "measure, don't infer" rule as M-21's drawable log.
        int pw = 0, ph = 0;
        sm64_metal_get_3d_render_size(&pw, &ph);
        UILabel *val = [UILabel new];
        if ([r.key isEqualToString:@"infoW"]) {
            val.text = [NSString stringWithFormat:@"%d px", pw];
        } else if ([r.key isEqualToString:@"infoH"]) {
            val.text = [NSString stringWithFormat:@"%d px", ph];
        } else {
            val.text = ph > 0 ? [NSString stringWithFormat:@"%d:9",
                                 (int)lroundf((float)pw * 9.0f / (float)ph)] : @"—";
        }
        val.textColor = [UIColor secondaryLabelColor];
        val.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
        [val sizeToFit];
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.accessoryView = val;
        return c;
    }
    if (r.type == SM64_ROW_SWITCH) {
        UISwitch *sw = [UISwitch new];
        sw.on = v > 0.5f;
        tag_ctl(sw, r);
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    // Item 6: when "Auto" is on, the Focus Distance is derived from the panel —
    // show the derived value and DISABLE the manual slider (turn Auto off to edit).
    BOOL sliderEnabled = YES;
    if ([r.key isEqualToString:@"conv"] &&
        sm64_3d_setting_f("convAuto", SM64_DEF_CONVAUTO) > 0.5f) {
        v = sm64_3d_auto_convergence();
        sliderEnabled = NO;
    }

    // Wide slider + live value readout (m/ft honouring the units toggle).
    const CGFloat labelW = 90, sliderW = 360, gap = 8;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sliderW + gap + labelW, 34)];
    UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 2, sliderW, 30)];
    UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(sliderW + gap, 2, labelW, 30)];
    val.textColor = sliderEnabled ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    val.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    val.textAlignment = NSTextAlignmentRight;
    val.text = sm64_value_text(r.key, v);
    objc_setAssociatedObject(sl, "sm64_val_label", val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sl.minimumValue = r.mn;
    sl.maximumValue = r.mx;
    sl.value = v;
    sl.enabled = sliderEnabled;
    tag_ctl(sl, r);
    [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [box addSubview:sl];
    [box addSubview:val];
    c.accessoryView = box;
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    SM64Row *r = _rows[ip.section][ip.row];
    if (r.type != SM64_ROW_BUTTON) { return; }
    [t deselectRowAtIndexPath:ip animated:YES];
    if ([r.key isEqualToString:@"recenter"]) {
        sm64_3d_recenter();
        NSLog(@"[sm64vp] settings: recenter requested");
    }
}

- (void)segChanged:(UISegmentedControl *)seg {
    sm64_3d_setting_set_f(ctl_row(seg).key.UTF8String, seg.selectedSegmentIndex > 0 ? 1.0f : 0.0f);
    [self.tableView reloadData]; // every value label changes with the units
}

- (void)switchChanged:(UISwitch *)sw {
    SM64Row *r = ctl_row(sw);
    sm64_3d_setting_set_f(r.key.UTF8String, sw.on ? 1.0f : 0.0f);
    sm64_3d_apply_settings();
    // Item 6: toggling Auto changes whether the Focus Distance slider is enabled
    // and what value it shows — reload so that row reflects it immediately.
    if ([r.key isEqualToString:@"convAuto"]) { [self.tableView reloadData]; }
}

- (void)sliderChanged:(UISlider *)sl {
    SM64Row *r = ctl_row(sl);
    sm64_3d_setting_set_f(r.key.UTF8String, sl.value);
    UILabel *val = objc_getAssociatedObject(sl, "sm64_val_label");
    if (val) { val.text = sm64_value_text(r.key, sl.value); }
    // Panel/stereo state is plain C — safe (and the entire point) to apply live
    // while dragging, with instant feedback on the 3D panel.
    sm64_3d_apply_settings();
}

@end

UIViewController *SM64_MakeSettingsNav(void) {
    return [[SM64SettingsVC alloc] initWithStyle:UITableViewStyleInsetGrouped];
}

// Bridged to the SwiftUI sheet header's Reset button (declared in
// sm64_vision_host.h). Marshals to the main thread and drives the live table's
// -resetVision3D (which clears the persisted values, re-applies, and reloads the
// visible sliders). Sending to a nil weak handle is a no-op, so this is safe when
// the sheet is closed.
void SM64_ResetVision3D(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_settingsVC resetVision3D];
    });
}

#endif // SM64_VISION_3D
