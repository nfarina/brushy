import Foundation

/// Layer styles across the PSD boundary: Adobe's `lfx2` effect descriptor in
/// both directions, so a styled layer survives a round trip through
/// Photoshop.
///
/// Only the seven effects this app models are mapped (see `LayerEffects`).
/// Reading a PSD whose layers carry Bevel & Emboss, Satin or Pattern Overlay
/// keeps everything else and drops those — better a mostly-right style than
/// no style. Writing emits just the modelled effects, so Photoshop opens the
/// file with exactly what Brushy showed.
///
/// Sizes and distances need no conversion in either direction: PSD effect
/// units are document pixels, `LayerEffects` units are canvas points, and
/// those are the same thing (and the PSD writer bakes layer transforms
/// into pixels).
enum PSDEffects {
    // Effect keys inside the lfx2 descriptor.
    private enum Key {
        static let dropShadow = "DrSh"
        static let innerShadow = "IrSh"
        static let outerGlow = "OrGl"
        static let innerGlow = "IrGl"
        static let stroke = "FrFX"
        static let colorOverlay = "SoFi"
        static let gradientOverlay = "GrFl"
        static let masterSwitch = "masterFXSwitch"
        static let scale = "Scl "
    }

    // MARK: - Read

    /// Decodes an `lfx2` block: version, descriptor version, then the
    /// descriptor itself.
    static func effects(fromLFX2 payload: Data) throws -> LayerEffects {
        var reader = PSDByteReader(payload)
        _ = try reader.u32()                      // version (0)
        _ = try reader.u32()                      // descriptor version (16)
        let descriptor = try PSDDescriptor(reading: &reader)
        // "Scale Effects" is folded into every distance below, so even a
        // well-formed file can land a size no slider could produce — and
        // sizes are blur radii the renderer has to honour.
        return effects(from: descriptor).sanitized()
    }

    static func effects(from descriptor: PSDDescriptor) -> LayerEffects {
        var effects = LayerEffects()
        effects.isEnabled = descriptor[Key.masterSwitch]?.boolValue ?? true
        // Photoshop's "Scale Effects" multiplies every distance in the style;
        // folding it in on import keeps the picture right, and export writes
        // 100% because the scaling is already in the numbers.
        let scale = percent(descriptor[Key.scale]) ?? 1

        if let shadow = descriptor[Key.dropShadow]?.descriptorValue {
            var effect = DropShadowEffect()
            effect.isEnabled = shadow["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(shadow["Md  "])
            effect.color = color(shadow["Clr "]) ?? .black
            effect.opacity = percent(shadow["Opct"]) ?? 0.35
            effect.usesGlobalLight = shadow["uglg"]?.boolValue ?? true
            effect.angle = shadow["lagl"]?.doubleValue ?? 120
            effect.distance = (shadow["Dstn"]?.doubleValue ?? 5) * scale
            effect.size = (shadow["blur"]?.doubleValue ?? 5) * scale
            effect.spread = spread(shadow["Ckmt"], size: effect.size)
            effect.knocksOut = shadow["layerConceals"]?.boolValue ?? true
            if effect.usesGlobalLight { effects.globalLightAngle = effect.angle }
            effects.dropShadow = effect
        }
        if let shadow = descriptor[Key.innerShadow]?.descriptorValue {
            var effect = InnerShadowEffect()
            effect.isEnabled = shadow["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(shadow["Md  "])
            effect.color = color(shadow["Clr "]) ?? .black
            effect.opacity = percent(shadow["Opct"]) ?? 0.35
            effect.usesGlobalLight = shadow["uglg"]?.boolValue ?? true
            effect.angle = shadow["lagl"]?.doubleValue ?? 120
            effect.distance = (shadow["Dstn"]?.doubleValue ?? 5) * scale
            effect.size = (shadow["blur"]?.doubleValue ?? 5) * scale
            effect.choke = spread(shadow["Ckmt"], size: effect.size)
            if effect.usesGlobalLight { effects.globalLightAngle = effect.angle }
            effects.innerShadow = effect
        }
        if let glow = descriptor[Key.outerGlow]?.descriptorValue {
            var effect = OuterGlowEffect()
            effect.isEnabled = glow["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(glow["Md  "], default: .screen)
            effect.color = color(glow["Clr "]) ?? .glowYellow
            effect.opacity = percent(glow["Opct"]) ?? 0.75
            effect.size = (glow["blur"]?.doubleValue ?? 5) * scale
            effect.spread = spread(glow["Ckmt"], size: effect.size)
            effects.outerGlow = effect
        }
        if let glow = descriptor[Key.innerGlow]?.descriptorValue {
            var effect = InnerGlowEffect()
            effect.isEnabled = glow["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(glow["Md  "], default: .screen)
            effect.color = color(glow["Clr "]) ?? .glowYellow
            effect.opacity = percent(glow["Opct"]) ?? 0.75
            effect.size = (glow["blur"]?.doubleValue ?? 5) * scale
            effect.choke = spread(glow["Ckmt"], size: effect.size)
            effects.innerGlow = effect
        }
        if let stroke = descriptor[Key.stroke]?.descriptorValue {
            var effect = StrokeEffect()
            effect.isEnabled = stroke["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(stroke["Md  "])
            effect.opacity = percent(stroke["Opct"]) ?? 1
            effect.size = (stroke["Sz  "]?.doubleValue ?? 3) * scale
            effect.color = color(stroke["Clr "]) ?? .red
            switch stroke["Styl"]?.enumValue {
            case "InsF": effect.position = .inside
            case "CtrF": effect.position = .center
            default: effect.position = .outside
            }
            effects.stroke = effect
        }
        if let overlay = descriptor[Key.colorOverlay]?.descriptorValue {
            var effect = ColorOverlayEffect()
            effect.isEnabled = overlay["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(overlay["Md  "])
            effect.opacity = percent(overlay["Opct"]) ?? 1
            effect.color = color(overlay["Clr "]) ?? .red
            effects.colorOverlay = effect
        }
        if let overlay = descriptor[Key.gradientOverlay]?.descriptorValue {
            var effect = GradientOverlayEffect()
            effect.isEnabled = overlay["enab"]?.boolValue ?? true
            effect.blendMode = blendMode(overlay["Md  "])
            effect.opacity = percent(overlay["Opct"]) ?? 1
            effect.angle = overlay["Angl"]?.doubleValue ?? 90
            effect.scale = percent(overlay["Scl "]) ?? 1
            effect.reversed = overlay["Rvrs"]?.boolValue ?? false
            // Angle/Reflected/Diamond aren't modelled — they import as Linear
            // (documented on `GradientOverlayEffect.Style`).
            effect.style = overlay["Type"]?.enumValue == "Rdl " ? .radial : .linear
            if let stops = gradientStops(overlay["Grad"]?.descriptorValue) {
                effect.startColor = stops.start
                effect.endColor = stops.end
            }
            effects.gradientOverlay = effect
        }
        return effects
    }

    // MARK: - Write

    /// The `lfx2` payload for a layer's style, or nil when there is nothing
    /// to write.
    static func lfx2Payload(for effects: LayerEffects) -> Data? {
        guard !effects.isEmpty else { return nil }
        var out = Data()
        out.appendU32(0)                          // version
        out.appendU32(16)                         // descriptor version
        out.append(descriptor(for: effects).encoded())
        return out
    }

    static func descriptor(for effects: LayerEffects) -> PSDDescriptor {
        var descriptor = PSDDescriptor(name: "", classID: "null")
        descriptor[Key.scale] = .unitFloat(unit: "#Prc", value: 100)
        descriptor[Key.masterSwitch] = .boolean(effects.isEnabled)

        if let shadow = effects.dropShadow {
            var item = PSDDescriptor(classID: "DrSh")
            item["enab"] = .boolean(shadow.isEnabled)
            item["Md  "] = blendValue(shadow.blendMode)
            item["Clr "] = colorValue(shadow.color)
            item["Opct"] = .unitFloat(unit: "#Prc", value: shadow.opacity * 100)
            item["uglg"] = .boolean(shadow.usesGlobalLight)
            item["lagl"] = .unitFloat(unit: "#Ang",
                                      value: shadow.usesGlobalLight ? effects.globalLightAngle
                                                                    : shadow.angle)
            item["Dstn"] = .unitFloat(unit: "#Pxl", value: shadow.distance)
            item["Ckmt"] = .unitFloat(unit: "#Prc", value: shadow.spread * 100)
            item["blur"] = .unitFloat(unit: "#Pxl", value: shadow.size)
            item["Nose"] = .unitFloat(unit: "#Prc", value: 0)
            item["AntA"] = .boolean(false)
            item["layerConceals"] = .boolean(shadow.knocksOut)
            descriptor[Key.dropShadow] = .descriptor(item)
        }
        if let shadow = effects.innerShadow {
            var item = PSDDescriptor(classID: "IrSh")
            item["enab"] = .boolean(shadow.isEnabled)
            item["Md  "] = blendValue(shadow.blendMode)
            item["Clr "] = colorValue(shadow.color)
            item["Opct"] = .unitFloat(unit: "#Prc", value: shadow.opacity * 100)
            item["uglg"] = .boolean(shadow.usesGlobalLight)
            item["lagl"] = .unitFloat(unit: "#Ang",
                                      value: shadow.usesGlobalLight ? effects.globalLightAngle
                                                                    : shadow.angle)
            item["Dstn"] = .unitFloat(unit: "#Pxl", value: shadow.distance)
            item["Ckmt"] = .unitFloat(unit: "#Prc", value: shadow.choke * 100)
            item["blur"] = .unitFloat(unit: "#Pxl", value: shadow.size)
            item["Nose"] = .unitFloat(unit: "#Prc", value: 0)
            item["AntA"] = .boolean(false)
            descriptor[Key.innerShadow] = .descriptor(item)
        }
        if let glow = effects.outerGlow {
            var item = PSDDescriptor(classID: "OrGl")
            item["enab"] = .boolean(glow.isEnabled)
            item["Md  "] = blendValue(glow.blendMode)
            item["Clr "] = colorValue(glow.color)
            item["Opct"] = .unitFloat(unit: "#Prc", value: glow.opacity * 100)
            item["GlwT"] = .enumerated(type: "BETE", value: "SfBL")   // softer
            item["Ckmt"] = .unitFloat(unit: "#Prc", value: glow.spread * 100)
            item["blur"] = .unitFloat(unit: "#Pxl", value: glow.size)
            item["Nose"] = .unitFloat(unit: "#Prc", value: 0)
            item["ShdN"] = .unitFloat(unit: "#Prc", value: 0)
            item["AntA"] = .boolean(false)
            descriptor[Key.outerGlow] = .descriptor(item)
        }
        if let glow = effects.innerGlow {
            var item = PSDDescriptor(classID: "IrGl")
            item["enab"] = .boolean(glow.isEnabled)
            item["Md  "] = blendValue(glow.blendMode)
            item["Clr "] = colorValue(glow.color)
            item["Opct"] = .unitFloat(unit: "#Prc", value: glow.opacity * 100)
            item["GlwT"] = .enumerated(type: "BETE", value: "SfBL")
            item["Ckmt"] = .unitFloat(unit: "#Prc", value: glow.choke * 100)
            item["blur"] = .unitFloat(unit: "#Pxl", value: glow.size)
            item["Nose"] = .unitFloat(unit: "#Prc", value: 0)
            item["AntA"] = .boolean(false)
            // Source: Edge — the only variant modelled.
            item["glwS"] = .enumerated(type: "IGSr", value: "SrcE")
            descriptor[Key.innerGlow] = .descriptor(item)
        }
        if let stroke = effects.stroke {
            var item = PSDDescriptor(classID: "FrFX")
            item["enab"] = .boolean(stroke.isEnabled)
            item["Styl"] = .enumerated(type: "FStl", value: {
                switch stroke.position {
                case .outside: return "OutF"
                case .inside: return "InsF"
                case .center: return "CtrF"
                }
            }())
            item["PntT"] = .enumerated(type: "FrFl", value: "SClr")   // solid colour
            item["Md  "] = blendValue(stroke.blendMode)
            item["Opct"] = .unitFloat(unit: "#Prc", value: stroke.opacity * 100)
            item["Sz  "] = .unitFloat(unit: "#Pxl", value: stroke.size)
            item["Clr "] = colorValue(stroke.color)
            descriptor[Key.stroke] = .descriptor(item)
        }
        if let overlay = effects.colorOverlay {
            var item = PSDDescriptor(classID: "SoFi")
            item["enab"] = .boolean(overlay.isEnabled)
            item["Md  "] = blendValue(overlay.blendMode)
            item["Clr "] = colorValue(overlay.color)
            item["Opct"] = .unitFloat(unit: "#Prc", value: overlay.opacity * 100)
            descriptor[Key.colorOverlay] = .descriptor(item)
        }
        if let overlay = effects.gradientOverlay {
            var item = PSDDescriptor(classID: "GrFl")
            item["enab"] = .boolean(overlay.isEnabled)
            item["Md  "] = blendValue(overlay.blendMode)
            item["Opct"] = .unitFloat(unit: "#Prc", value: overlay.opacity * 100)
            item["Grad"] = .descriptor(gradientDescriptor(start: overlay.startColor,
                                                          end: overlay.endColor))
            item["Angl"] = .unitFloat(unit: "#Ang", value: overlay.angle)
            item["Type"] = .enumerated(type: "GrdT",
                                       value: overlay.style == .radial ? "Rdl " : "Lnr ")
            item["Rvrs"] = .boolean(overlay.reversed)
            item["Algn"] = .boolean(true)
            item["Scl "] = .unitFloat(unit: "#Prc", value: overlay.scale * 100)
            descriptor[Key.gradientOverlay] = .descriptor(item)
        }
        return descriptor
    }

    // MARK: - Value helpers

    /// Descriptors name blend modes with their own enum keys, which are NOT
    /// the four-character keys in the layer record (`BlendMode.psdKey`).
    private static func blendMode(_ value: PSDDescriptorValue?,
                                  default fallback: BlendMode = .normal) -> BlendMode {
        guard let key = value?.enumValue else { return fallback }
        return BlendMode(psdDescriptorKey: key) ?? fallback
    }

    private static func blendValue(_ mode: BlendMode) -> PSDDescriptorValue {
        .enumerated(type: "BlnM", value: mode.psdDescriptorKey)
    }

    /// Photoshop percentages are 0…100; the model's are 0…1.
    private static func percent(_ value: PSDDescriptorValue?) -> Double? {
        value?.doubleValue.map { $0 / 100 }
    }

    /// Spread/Choke reads as a percentage in every file seen, but the spec
    /// leaves the unit open — a pixel-tagged value is interpreted against the
    /// effect's own size so it still lands in 0…1.
    private static func spread(_ value: PSDDescriptorValue?, size: Double) -> Double {
        guard let value, let raw = value.doubleValue else { return 0 }
        let fraction = value.unit == "#Pxl" && size > 0 ? raw / size : raw / 100
        return min(max(fraction, 0), 1)
    }

    /// Photoshop's `RGBC` colour object: components 0…255 in the document's
    /// RGB space, which `EffectColor` holds as sRGB 0…1.
    private static func color(_ value: PSDDescriptorValue?) -> EffectColor? {
        guard let object = value?.descriptorValue,
              let red = object["Rd  "]?.doubleValue,
              let green = object["Grn "]?.doubleValue,
              let blue = object["Bl  "]?.doubleValue else { return nil }
        return EffectColor(red: min(max(red / 255, 0), 1),
                           green: min(max(green / 255, 0), 1),
                           blue: min(max(blue / 255, 0), 1))
    }

    private static func colorValue(_ color: EffectColor) -> PSDDescriptorValue {
        var object = PSDDescriptor(classID: "RGBC")
        object["Rd  "] = .double(color.red * 255)
        object["Grn "] = .double(color.green * 255)
        object["Bl  "] = .double(color.blue * 255)
        return .descriptor(object)
    }

    /// The first and last colour stops of Photoshop's gradient object — the
    /// two this app's two-stop ramp can hold. Stop locations run 0…4096.
    private static func gradientStops(_ gradient: PSDDescriptor?)
        -> (start: EffectColor, end: EffectColor)? {
        guard let stops = gradient?["Clrs"]?.listValue, stops.count >= 2 else { return nil }
        let sorted = stops.compactMap { value -> (location: Double, color: EffectColor)? in
            guard let stop = value.descriptorValue, let color = color(stop["Clr "]) else {
                return nil
            }
            return (stop["Lctn"]?.doubleValue ?? 0, color)
        }.sorted { $0.location < $1.location }
        guard let first = sorted.first, let last = sorted.last, sorted.count >= 2 else {
            return nil
        }
        return (first.color, last.color)
    }

    private static func gradientDescriptor(start: EffectColor, end: EffectColor) -> PSDDescriptor {
        func stop(_ color: EffectColor, at location: Int32) -> PSDDescriptorValue {
            var item = PSDDescriptor(classID: "Clrt")
            item["Clr "] = colorValue(color)
            item["Type"] = .enumerated(type: "Clry", value: "UsrS")
            item["Lctn"] = .integer(location)
            item["Mdpn"] = .integer(50)
            return .descriptor(item)
        }
        func transparency(at location: Int32) -> PSDDescriptorValue {
            var item = PSDDescriptor(classID: "TrnS")
            item["Opct"] = .unitFloat(unit: "#Prc", value: 100)
            item["Lctn"] = .integer(location)
            item["Mdpn"] = .integer(50)
            return .descriptor(item)
        }
        var gradient = PSDDescriptor(classID: "Grdn")
        gradient["Nm  "] = .text("Custom")
        gradient["GrdF"] = .enumerated(type: "GrdF", value: "CstS")
        gradient["Intr"] = .double(4096)
        gradient["Clrs"] = .list([stop(start, at: 0), stop(end, at: 4096)])
        gradient["Trns"] = .list([transparency(at: 0), transparency(at: 4096)])
        return gradient
    }
}

extension BlendMode {
    /// Adobe's *descriptor* enum key for the mode — distinct from `psdKey`,
    /// the four-character code in the layer record. Photoshop uses both, in
    /// different parts of the same file.
    var psdDescriptorKey: String {
        switch self {
        case .normal: return "Nrml"
        case .darken: return "Drkn"
        case .multiply: return "Mltp"
        case .colorBurn: return "CBrn"
        case .lighten: return "Lghn"
        case .screen: return "Scrn"
        case .colorDodge: return "CDdg"
        case .overlay: return "Ovrl"
        case .softLight: return "SftL"
        case .hardLight: return "HrdL"
        case .difference: return "Dfrn"
        case .exclusion: return "Xclu"
        case .hue: return "H   "
        case .saturation: return "Strt"
        case .color: return "Clr "
        case .luminosity: return "Lmns"
        }
    }

    init?(psdDescriptorKey key: String) {
        guard let match = BlendMode.allCases.first(where: { $0.psdDescriptorKey == key }) else {
            return nil
        }
        self = match
    }
}
