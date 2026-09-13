import CoreGraphics
import Foundation

/// Layer effects — Photoshop's Layer Style.
///
/// Seven effects are modelled, the ones that render as pure alpha-morphology +
/// blur + colourise passes over the layer's own coverage: Drop Shadow, Inner
/// Shadow, Outer Glow, Inner Glow, Stroke, Colour Overlay and Gradient
/// Overlay. Bevel & Emboss, Satin and Pattern Overlay are deliberately absent
/// — they need a lighting model / a pattern library, and neither is here.
///
/// Everything is a value type hanging off `Layer`, so effects ride the
/// `Document -> Document` invariant and undo comes free.
///
/// Units: **canvas points** for distances and sizes, degrees for angles,
/// 0...1 for opacities — the same space the layer's transformed pixels live
/// in, which is what makes an effect independent of the layer's own scale
/// (Photoshop has no layer transforms; its effect sizes are document pixels).
struct LayerEffects: Equatable, Codable {
    /// The master fx switch — Photoshop's "Effects" eye in the layers panel.
    /// Off keeps every effect's parameters but renders none of them.
    var isEnabled: Bool = true
    /// Photoshop's global light: shared by Drop Shadow and Inner Shadow when
    /// their `usesGlobalLight` is set. Per layer here rather than per
    /// document — the document-wide dial is UI sugar we don't have.
    var globalLightAngle: Double = 120
    var dropShadow: DropShadowEffect?
    var innerShadow: InnerShadowEffect?
    var outerGlow: OuterGlowEffect?
    var innerGlow: InnerGlowEffect?
    var stroke: StrokeEffect?
    var colorOverlay: ColorOverlayEffect?
    var gradientOverlay: GradientOverlayEffect?

    static let none = LayerEffects()

    /// No effect is present at all — the state a layer has unless the user
    /// opens Layer Style. Serialization omits the whole key in this state, so
    /// documents written before effects existed round-trip byte-identically.
    var isEmpty: Bool {
        dropShadow == nil && innerShadow == nil && outerGlow == nil && innerGlow == nil
            && stroke == nil && colorOverlay == nil && gradientOverlay == nil
    }

    /// Something will actually draw: the master switch is on and at least one
    /// effect is present and enabled. The renderer's fast path keys off this,
    /// so a layer whose effects are all unchecked costs exactly what it did
    /// before this feature existed.
    var isActive: Bool {
        guard isEnabled else { return false }
        return enabledDropShadow != nil || enabledInnerShadow != nil
            || enabledOuterGlow != nil || enabledInnerGlow != nil
            || enabledStroke != nil || enabledColorOverlay != nil
            || enabledGradientOverlay != nil
    }

    var enabledDropShadow: DropShadowEffect? { isEnabled ? dropShadow?.ifEnabled : nil }
    var enabledInnerShadow: InnerShadowEffect? { isEnabled ? innerShadow?.ifEnabled : nil }
    var enabledOuterGlow: OuterGlowEffect? { isEnabled ? outerGlow?.ifEnabled : nil }
    var enabledInnerGlow: InnerGlowEffect? { isEnabled ? innerGlow?.ifEnabled : nil }
    var enabledStroke: StrokeEffect? { isEnabled ? stroke?.ifEnabled : nil }
    var enabledColorOverlay: ColorOverlayEffect? { isEnabled ? colorOverlay?.ifEnabled : nil }
    var enabledGradientOverlay: GradientOverlayEffect? {
        isEnabled ? gradientOverlay?.ifEnabled : nil
    }

    /// How far, in canvas points, the rendered result can reach outside the
    /// layer's own coverage. The renderer insets the layer bounds by this to
    /// size its intermediate rasters, and the panel/export paths use it to
    /// know a styled layer's true bounds.
    var outsetInCanvasPoints: CGFloat {
        var outset: CGFloat = 0
        if let shadow = enabledDropShadow {
            outset = max(outset, CGFloat(shadow.size + shadow.spread * shadow.size + shadow.distance))
        }
        if let glow = enabledOuterGlow {
            outset = max(outset, CGFloat(glow.size + glow.spread * glow.size))
        }
        if let stroke = enabledStroke, stroke.position != .inside {
            outset = max(outset, CGFloat(stroke.position == .center ? stroke.size / 2 : stroke.size))
        }
        return outset
    }

    /// How far OUTSIDE the layer the interior effects' mattes have to be
    /// built. Inner shadow and inner glow are cast by the hole around the
    /// layer, so their source matte must exist that far beyond the edge even
    /// though nothing they draw ends up outside it.
    var interiorSourceReachInCanvasPoints: CGFloat {
        var reach: CGFloat = 0
        if let shadow = enabledInnerShadow {
            reach = max(reach, CGFloat(shadow.size + shadow.choke * shadow.size + shadow.distance))
        }
        if let glow = enabledInnerGlow {
            reach = max(reach, CGFloat(glow.size + glow.choke * glow.size))
        }
        return reach
    }

    /// The user-facing effect list, in Photoshop's dialog order — drives the
    /// effects panel, the fx badge tooltip and the menu.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case dropShadow, innerShadow, outerGlow, innerGlow, stroke
        case colorOverlay, gradientOverlay

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dropShadow: return "Drop Shadow"
            case .innerShadow: return "Inner Shadow"
            case .outerGlow: return "Outer Glow"
            case .innerGlow: return "Inner Glow"
            case .stroke: return "Stroke"
            case .colorOverlay: return "Color Overlay"
            case .gradientOverlay: return "Gradient Overlay"
            }
        }
    }

    /// Whether the effect exists AND is checked — the state of the dialog's
    /// checkbox and the fx sub-rows.
    func isOn(_ kind: Kind) -> Bool {
        switch kind {
        case .dropShadow: return dropShadow?.isEnabled ?? false
        case .innerShadow: return innerShadow?.isEnabled ?? false
        case .outerGlow: return outerGlow?.isEnabled ?? false
        case .innerGlow: return innerGlow?.isEnabled ?? false
        case .stroke: return stroke?.isEnabled ?? false
        case .colorOverlay: return colorOverlay?.isEnabled ?? false
        case .gradientOverlay: return gradientOverlay?.isEnabled ?? false
        }
    }

    /// Checking an effect that was never configured materialises it at
    /// Photoshop's defaults; unchecking keeps the parameters, like Photoshop.
    mutating func setOn(_ kind: Kind, _ on: Bool) {
        switch kind {
        case .dropShadow:
            dropShadow = (dropShadow ?? DropShadowEffect()).setting(on)
        case .innerShadow:
            innerShadow = (innerShadow ?? InnerShadowEffect()).setting(on)
        case .outerGlow:
            outerGlow = (outerGlow ?? OuterGlowEffect()).setting(on)
        case .innerGlow:
            innerGlow = (innerGlow ?? InnerGlowEffect()).setting(on)
        case .stroke:
            stroke = (stroke ?? StrokeEffect()).setting(on)
        case .colorOverlay:
            colorOverlay = (colorOverlay ?? ColorOverlayEffect()).setting(on)
        case .gradientOverlay:
            gradientOverlay = (gradientOverlay ?? GradientOverlayEffect()).setting(on)
        }
    }

    /// Whether the effect exists at all, checked or not — the effects panel
    /// lists these.
    func isPresent(_ kind: Kind) -> Bool {
        switch kind {
        case .dropShadow: return dropShadow != nil
        case .innerShadow: return innerShadow != nil
        case .outerGlow: return outerGlow != nil
        case .innerGlow: return innerGlow != nil
        case .stroke: return stroke != nil
        case .colorOverlay: return colorOverlay != nil
        case .gradientOverlay: return gradientOverlay != nil
        }
    }

    /// Deletes the effect and its parameters (unchecking keeps them).
    mutating func remove(_ kind: Kind) {
        switch kind {
        case .dropShadow: dropShadow = nil
        case .innerShadow: innerShadow = nil
        case .outerGlow: outerGlow = nil
        case .innerGlow: innerGlow = nil
        case .stroke: stroke = nil
        case .colorOverlay: colorOverlay = nil
        case .gradientOverlay: gradientOverlay = nil
        }
    }

    /// Switches an effect on from the effects panel. An effect that was only
    /// unchecked comes back as it was; a new one gets distances sized to the
    /// layer, because Photoshop's fixed 5 px defaults are invisible on a
    /// large layer (about 1 screen pixel for a 900 px icon at 22%).
    mutating func add(_ kind: Kind, layerSize: CGSize) {
        guard !isPresent(kind) else { return setOn(kind, true) }
        let side = Double(min(layerSize.width, layerSize.height))
        func scaled(_ fraction: Double, floor minimum: Double) -> Double {
            guard side.isFinite else { return minimum }
            return min(max((side * fraction).rounded(), minimum), Bounds.point.upperBound)
        }
        switch kind {
        case .dropShadow:
            var e = DropShadowEffect()
            e.distance = scaled(0.02, floor: 5)
            e.size = scaled(0.06, floor: 5)
            e.opacity = 0.5
            dropShadow = e
        case .innerShadow:
            var e = InnerShadowEffect()
            e.distance = scaled(0.01, floor: 5)
            e.size = scaled(0.03, floor: 5)
            innerShadow = e
        case .outerGlow:
            var e = OuterGlowEffect()
            e.size = scaled(0.04, floor: 5)
            outerGlow = e
        case .innerGlow:
            var e = InnerGlowEffect()
            e.size = scaled(0.03, floor: 5)
            innerGlow = e
        case .stroke:
            var e = StrokeEffect()
            e.size = scaled(0.006, floor: 3)
            stroke = e
        case .colorOverlay, .gradientOverlay:
            setOn(kind, true)
        }
    }

    /// The enabled effects, top-to-bottom in Photoshop's fx sub-row order.
    var activeKinds: [Kind] { Kind.allCases.filter { isOn($0) } }

    // MARK: - Sanitising

    /// The bounds `LayerEffectsPanel` already enforces on every field, applied
    /// to a style that did NOT come from that panel.
    ///
    /// Effects arrive from two places the UI doesn't police: `document.json`
    /// inside a `.brushy` package, and Photoshop's `lfx2` descriptor — where
    /// "Scale Effects" is a multiplier folded into every distance on import,
    /// so even a well-formed file can produce a size no slider could. Sizes
    /// are blur radii in canvas points; an unbounded one is a Gaussian the
    /// renderer will not finish.
    enum Bounds {
        static let point: ClosedRange<Double> = 0...250
        static let strokePoint: ClosedRange<Double> = 1...250
        static let percent: ClosedRange<Double> = 0...1
        static let degrees: ClosedRange<Double> = -180...180
        static let gradientScale: ClosedRange<Double> = 0.1...3
    }

    /// Clamps every numeric field into `Bounds`, mapping non-finite values to
    /// the field's default rather than to a bound — NaN means "no information
    /// here", not "the smallest legal value".
    func sanitized() -> LayerEffects {
        var copy = self
        copy.globalLightAngle = Self.clamp(globalLightAngle, Bounds.degrees, default: 120)
        copy.dropShadow = dropShadow.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 0.35)
            e.angle = Self.clamp(e.angle, Bounds.degrees, default: 120)
            e.distance = Self.clamp(e.distance, Bounds.point, default: 5)
            e.spread = Self.clamp(e.spread, Bounds.percent, default: 0)
            e.size = Self.clamp(e.size, Bounds.point, default: 5)
            return e
        }
        copy.innerShadow = innerShadow.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 0.35)
            e.angle = Self.clamp(e.angle, Bounds.degrees, default: 120)
            e.distance = Self.clamp(e.distance, Bounds.point, default: 5)
            e.choke = Self.clamp(e.choke, Bounds.percent, default: 0)
            e.size = Self.clamp(e.size, Bounds.point, default: 5)
            return e
        }
        copy.outerGlow = outerGlow.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 0.75)
            e.spread = Self.clamp(e.spread, Bounds.percent, default: 0)
            e.size = Self.clamp(e.size, Bounds.point, default: 5)
            return e
        }
        copy.innerGlow = innerGlow.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 0.75)
            e.choke = Self.clamp(e.choke, Bounds.percent, default: 0)
            e.size = Self.clamp(e.size, Bounds.point, default: 5)
            return e
        }
        copy.stroke = stroke.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 1)
            e.size = Self.clamp(e.size, Bounds.strokePoint, default: 3)
            return e
        }
        copy.colorOverlay = colorOverlay.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 1)
            return e
        }
        copy.gradientOverlay = gradientOverlay.map { effect in
            var e = effect
            e.opacity = Self.clamp(e.opacity, Bounds.percent, default: 1)
            e.angle = Self.clamp(e.angle, Bounds.degrees, default: 90)
            e.scale = Self.clamp(e.scale, Bounds.gradientScale, default: 1)
            return e
        }
        return copy
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>,
                              default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Shared shape of every effect: a checkbox, a blend mode and an opacity.
protocol LayerEffect: Equatable, Codable {
    /// Photoshop's defaults.
    init()
    var isEnabled: Bool { get set }
    var blendMode: BlendMode { get set }
    var opacity: Double { get set }
}

extension LayerEffect {
    /// `self` when checked, nil otherwise — lets the renderer write
    /// `effects.enabledDropShadow.map { … }` and never think about the flag.
    var ifEnabled: Self? { isEnabled ? self : nil }

    func setting(_ enabled: Bool) -> Self {
        var copy = self
        copy.isEnabled = enabled
        return copy
    }
}

/// An effect painted in one colour — everything but Gradient Overlay. Lets
/// the effects panel build its blend-and-colour row once.
protocol ColoredLayerEffect: LayerEffect {
    var color: EffectColor { get set }
}

extension DropShadowEffect: ColoredLayerEffect {}
extension InnerShadowEffect: ColoredLayerEffect {}
extension OuterGlowEffect: ColoredLayerEffect {}
extension InnerGlowEffect: ColoredLayerEffect {}
extension StrokeEffect: ColoredLayerEffect {}
extension ColorOverlayEffect: ColoredLayerEffect {}

/// An sRGB colour that survives JSON and PSD round trips. The UI colour wells
/// hold sRGB `CGColor`s (`ToolOptionsBar.colorBinding`), Photoshop's
/// `RGBC` descriptor is 0...255 sRGB, so sRGB is the honest storage.
struct EffectColor: Equatable, Codable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From any `CGColor`, converted into sRGB when it isn't already.
    init(_ color: CGColor) {
        let srgb = color.converted(to: BrushyColorSpace.sRGB,
                                   intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0, 1]
        red = c.count > 0 ? Double(c[0]) : 0
        green = c.count > 2 ? Double(c[1]) : red
        blue = c.count > 2 ? Double(c[2]) : red
    }

    static let black = EffectColor(red: 0, green: 0, blue: 0)
    static let white = EffectColor(red: 1, green: 1, blue: 1)
    static let red = EffectColor(red: 1, green: 0, blue: 0)
    /// Photoshop's default glow colour, #FFFFBE.
    static let glowYellow = EffectColor(red: 1, green: 1, blue: 190.0 / 255)

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

// MARK: - The effects

/// Photoshop's Drop Shadow: the layer's coverage, choked by `spread`, blurred
/// by `size`, offset along the light angle and painted in `color`.
struct DropShadowEffect: LayerEffect {
    var isEnabled: Bool = true
    var blendMode: BlendMode = .multiply
    var color: EffectColor = .black
    var opacity: Double = 0.35
    /// Degrees, Photoshop's dial: the direction the light comes FROM, so the
    /// shadow falls the opposite way (120° ⇒ down and to the right).
    var angle: Double = 120
    var usesGlobalLight: Bool = true
    /// Canvas points the shadow is displaced from the layer.
    var distance: Double = 5
    /// 0...1 — the fraction of `size` spent dilating the coverage before the
    /// blur, which hardens the shadow's edge.
    var spread: Double = 0
    /// Canvas points of blur.
    var size: Double = 5
    /// Photoshop's "Layer Knocks Out Drop Shadow": a layer below full opacity
    /// doesn't show its own shadow through itself. At full opacity it changes
    /// nothing (see `LayerEffectRenderer.knockoutMask`).
    var knocksOut: Bool = true
}

/// Inner Shadow: the same construction inverted — the shadow is cast by the
/// hole around the layer, offset inward and confined to the layer's coverage.
struct InnerShadowEffect: LayerEffect {
    var isEnabled: Bool = true
    var blendMode: BlendMode = .multiply
    var color: EffectColor = .black
    var opacity: Double = 0.35
    var angle: Double = 120
    var usesGlobalLight: Bool = true
    var distance: Double = 5
    /// 0...1, Photoshop's "Choke" — the inner-shadow twin of spread.
    var choke: Double = 0
    var size: Double = 5
}

/// Outer Glow: an un-offset shadow in glow colours, Screened outward.
struct OuterGlowEffect: LayerEffect {
    var isEnabled: Bool = true
    var blendMode: BlendMode = .screen
    var color: EffectColor = .glowYellow
    var opacity: Double = 0.75
    var spread: Double = 0
    var size: Double = 5
}

/// Inner Glow: glow growing inward from the layer's edge (Photoshop's
/// "Source: Edge"; the Centre variant is not modelled).
struct InnerGlowEffect: LayerEffect {
    var isEnabled: Bool = true
    var blendMode: BlendMode = .screen
    var color: EffectColor = .glowYellow
    var opacity: Double = 0.75
    var choke: Double = 0
    var size: Double = 5
}

/// Stroke: a band of colour along the layer's edge.
struct StrokeEffect: LayerEffect {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case outside, inside, center

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .outside: return "Outside"
            case .inside: return "Inside"
            case .center: return "Center"
            }
        }
    }

    var isEnabled: Bool = true
    var blendMode: BlendMode = .normal
    /// Photoshop's default stroke colour is red — deliberately loud.
    var color: EffectColor = .red
    var opacity: Double = 1
    /// Band width in canvas points.
    var size: Double = 3
    var position: Position = .outside
}

/// Colour Overlay: a flat colour filling the layer's coverage.
struct ColorOverlayEffect: LayerEffect {
    var isEnabled: Bool = true
    var blendMode: BlendMode = .normal
    var color: EffectColor = .red
    var opacity: Double = 1
}

/// Gradient Overlay: a two-stop ramp filling the layer's coverage, aligned to
/// the layer's bounds.
///
/// Photoshop's Angle/Reflected/Diamond styles are not modelled — Core Image
/// has no conical or reflected generator and a custom kernel is out of
/// proportion here. A PSD carrying one of those imports as Linear.
struct GradientOverlayEffect: LayerEffect {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case linear, radial

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .linear: return "Linear"
            case .radial: return "Radial"
            }
        }
    }

    var isEnabled: Bool = true
    var blendMode: BlendMode = .normal
    var opacity: Double = 1
    var startColor: EffectColor = .black
    var endColor: EffectColor = .white
    /// Degrees; 90° is Photoshop's default (bottom-to-top ramp).
    var angle: Double = 90
    /// Fraction of the layer's bounds the ramp spans (Photoshop's Scale).
    var scale: Double = 1
    var reversed: Bool = false
    var style: Style = .linear
}
