import AccessCore
import SwiftUI

/// The worker's ranked key aspects of a scan: the annotated plan and the list behind its numbered
/// badges. Tapping a badge on the plan, or a row in the list, selects the same finding, so people
/// who can't use the picture get everything from the list (and VoiceOver reads only the list).
struct ScanHighlightsView: View {
    let highlights: ScanHighlights
    @State private var selectedID: String?
    @State private var showsAll = false

    private static let collapsedCount = 8

    private var visible: [ScanHighlights.Item] {
        showsAll ? highlights.items : Array(highlights.items.prefix(Self.collapsedCount))
    }

    var body: some View {
        if let image = highlights.image, let data = image.pngData, let picture = UIImage(data: data) {
            PlanPicture(picture: picture, image: image, highlights: highlights, selectedID: $selectedID)
                .padding(.vertical, 6)
        }
        ForEach(visible) { item in
            Button { selectedID = selectedID == item.id ? nil : item.id } label: {
                HighlightRow(item: item, isSelected: selectedID == item.id)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.severity.highlightSeverityLabel): \(item.title)")
            .accessibilityValue(item.reason)
            .accessibilityAddTraits(selectedID == item.id ? [.isButton, .isSelected] : .isButton)
        }
        if highlights.items.count > Self.collapsedCount {
            Button(showsAll ? "Show fewer" : "Show all \(highlights.items.count)") { showsAll.toggle() }
        }
    }
}

private struct PlanPicture: View {
    let picture: UIImage
    let image: ScanHighlights.Image
    let highlights: ScanHighlights
    @Binding var selectedID: String?

    var body: some View {
        Image(uiImage: picture)
            .resizable()
            .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / CGFloat(image.width)
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { location in
                                let pixel = SIMD2<Float>(Float(location.x / scale), Float(location.y / scale))
                                let hit = highlights.item(atPixel: pixel, radius: Float(max(18, 28 / scale)))
                                selectedID = hit?.id == selectedID ? nil : hit?.id
                            }
                        if let item = highlights.items.first(where: { $0.id == selectedID }),
                           let anchor = item.anchorPixel {
                            Circle()
                                .strokeBorder(.white, lineWidth: 3)
                                .background(Circle().strokeBorder(item.severity.highlightColor, lineWidth: 6))
                                .frame(width: 34, height: 34)
                                .position(x: CGFloat(anchor.x) * scale, y: CGFloat(anchor.y) * scale)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Annotated plan with \(highlights.items.count) key findings")
            .accessibilityHint("The findings are listed below.")
    }
}

private struct HighlightRow: View {
    let item: ScanHighlights.Item
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(item.severity.highlightColor)
                if let number = item.number {
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Image(systemName: item.severity.highlightSymbol).font(.caption.weight(.bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium))
                if !item.reason.isEmpty {
                    Text(item.reason).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .background(isSelected ? item.severity.highlightColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

extension String {
    /// Matches the worker's overlay colors so a badge in the picture and its row agree.
    fileprivate var highlightColor: Color {
        switch self {
        case "barrier": return Color(red: 198 / 255, green: 40 / 255, blue: 40 / 255)
        case "warning": return Color(red: 199 / 255, green: 119 / 255, blue: 0)
        case "asset": return Color(red: 46 / 255, green: 157 / 255, blue: 87 / 255)
        default: return Color(red: 0, green: 113 / 255, blue: 227 / 255)
        }
    }

    fileprivate var highlightSymbol: String {
        switch self {
        case "barrier": return "xmark"
        case "warning": return "exclamationmark"
        case "asset": return "checkmark"
        default: return "info"
        }
    }

    fileprivate var highlightSeverityLabel: String {
        switch self {
        case "barrier": return "Barrier"
        case "warning": return "Caution"
        case "asset": return "Helpful"
        default: return "Note"
        }
    }
}
