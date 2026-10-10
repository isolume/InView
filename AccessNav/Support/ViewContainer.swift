import SwiftUI
import UIKit

/// Hosts a UIKit view owned by a controller, so SwiftUI updates never recreate it.
struct ViewContainer<Content: UIView>: UIViewRepresentable {
    let view: Content

    func makeUIView(context: Context) -> Content { view }
    func updateUIView(_ uiView: Content, context: Context) {}
}
