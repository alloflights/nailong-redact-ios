import SwiftUI

public enum GlassShapeStyle {
    case capsule
    case circle
    case roundedRect(CGFloat)
}

/// 适配 iOS 26 / macOS 26 液态玻璃容器；在旧系统自动退化为标准布局容器
public struct AdaptiveGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct AdaptiveGlassModifier: ViewModifier {
    let tint: Color?
    let interactive: Bool
    let shapeStyle: GlassShapeStyle

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            let baseGlass: Glass = {
                var g = Glass.regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            switch shapeStyle {
            case .capsule:
                content.glassEffect(baseGlass, in: .capsule)
            case .circle:
                content.glassEffect(baseGlass, in: .circle)
            case .roundedRect(let r):
                content.glassEffect(baseGlass, in: .rect(cornerRadius: r))
            }
        } else {
            switch shapeStyle {
            case .capsule:
                content
                    .background(tint?.opacity(0.24) ?? Color.clear)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
            case .circle:
                content
                    .background(tint?.opacity(0.24) ?? Color.clear)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
            case .roundedRect(let r):
                content
                    .background(tint?.opacity(0.24) ?? Color.clear)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.75))
            }
        }
    }
}

private struct AdaptiveGlassIDModifier<ID: Hashable & Sendable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

public extension View {
    func adaptiveGlass(
        tint: Color? = nil,
        interactive: Bool = true,
        shape: GlassShapeStyle = .capsule
    ) -> some View {
        modifier(AdaptiveGlassModifier(tint: tint, interactive: interactive, shapeStyle: shape))
    }

    func adaptiveGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(AdaptiveGlassIDModifier(id: id, namespace: namespace))
    }
}
