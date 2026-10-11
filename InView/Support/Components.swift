import AccessCore
import SwiftUI

// Buttons, by where they sit:
// - Floating over the camera or a map: `.glassProminent` for the one main action, `.glass` for the rest,
//   `.controlSize(.large)`, full width.
// - On solid content (Home, lists, the report): `.borderedProminent` / `.bordered` with a capsule border shape.
// - Destructive: the same style with `.tint(.red)`.
// - Toolbars and sheets: the system roles `.close`, `.cancel` and `.confirm`, which draw the standard glyphs.

extension View {
    /// The container for controls floating over the camera or a map.
    func glassPanel(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
    }
}

/// A short status line in a glass capsule, over the camera or a map.
struct StatusPill: View {
    let text: String
    var systemImage: String? = nil
    var isWorking = false
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 6 : 8) {
            if isWorking {
                ProgressView().controlSize(isCompact ? .mini : .regular)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.semibold))
        .padding(.horizontal, isCompact ? 10 : 16)
        .padding(.vertical, isCompact ? 6 : 10)
        .glassEffect(.regular, in: .capsule)
    }
}

/// A colored disc with a white glyph: the one marker for elevators, ramps, stairs and destinations, used in
/// lists, cards, legends and on every map.
struct KindBadge: View {
    /// The size on maps, where the badge also gets a white ring to stay readable over walls and furniture.
    nonisolated static let mapDiameter: CGFloat = 26
    nonisolated static let ringWidth: CGFloat = 2
    /// Glyph size as a share of the diameter.
    nonisolated static let glyphScale: CGFloat = 0.5

    let symbol: String
    let tint: Color
    var size: CGFloat = 32
    var isOnMap = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * Self.glyphScale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .padding(isOnMap ? Self.ringWidth : 0)
            .background(isOnMap ? Color.white : .clear, in: Circle())
            .accessibilityHidden(true)
    }
}

extension KindBadge {
    /// The map badge as an image, for renderers that draw with UIKit (the 3D map's labels), so every map
    /// shows exactly the same marker.
    @MainActor
    static func image(symbol: String, tint: Color, size: CGFloat = mapDiameter) -> UIImage {
        let key = "\(symbol) \(tint) \(size)"
        if let cached = imageCache[key] { return cached }
        let renderer = ImageRenderer(content: KindBadge(symbol: symbol, tint: tint, size: size, isOnMap: true)
            .environment(\.colorScheme, .light))
        renderer.scale = 3
        let image = renderer.uiImage ?? UIImage()
        imageCache[key] = image
        return image
    }

    @MainActor private static var imageCache: [String: UIImage] = [:]

    init(kind: AccessPoint.Kind, size: CGFloat = 32, isOnMap: Bool = false) {
        self.init(symbol: kind.symbolName, tint: kind.tint, size: size, isOnMap: isOnMap)
    }

    /// A place's badge: sign places show what their sign named.
    init(point: AccessPoint, size: CGFloat = 32, isOnMap: Bool = false) {
        self.init(symbol: point.symbolName, tint: point.tint, size: size, isOnMap: isOnMap)
    }

    init(kind: VisionDetection.Kind, size: CGFloat = 32, isOnMap: Bool = false) {
        self.init(symbol: kind.symbolName, tint: kind.tint, size: size, isOnMap: isOnMap)
    }
}

/// The close control for full-screen camera views, matching the toolbar close buttons elsewhere.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark", role: .close, action: action)
            .labelStyle(.iconOnly)
            .font(.headline)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}
