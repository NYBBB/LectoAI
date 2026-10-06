import AppKit
import LectoAICore
import SwiftUI

/// 阅读语言。主窗口与小窗各自记忆。
/// 主窗口阅读方式：三种字幕 + 低频更新的总结文章（U9）。
enum ReadingMode: String, CaseIterable, Identifiable {
    case original, bilingual, chinese, summary
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .original: "原文"
        case .bilingual: "双语"
        case .chinese: "中文"
        case .summary: "总结"
        }
    }
    var showsEnglish: Bool { self == .original || self == .bilingual }
    var showsChinese: Bool { self == .bilingual || self == .chinese }
}

/// 字号档位；⌘+/⌘− 在档位间移动。
enum CaptionScale {
    static let steps: [Double] = [0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]
    static func larger(_ value: Double) -> Double { steps.first { $0 > value + 0.01 } ?? steps.last! }
    static func smaller(_ value: Double) -> Double { steps.last { $0 < value - 0.01 } ?? steps.first! }
}

/// 标记与笔记的视觉：图标、颜色、默认文字。
struct NoteStyle {
    let icon: String
    let color: Color
    let label: String
    init(_ mark: NoteMark?) {
        switch mark {
        case .confused: icon = "questionmark.circle.fill"; color = .orange; label = String(localized: "没听懂")
        case .important: icon = "star.fill"; color = .yellow; label = String(localized: "重点")
        case nil: icon = "pencil.line"; color = .accentColor; label = String(localized: "笔记")
        }
    }
}

enum Format {
    /// 课堂记录里显示的时长，如“45 秒”“52 分钟”“1 小时 13 分”。
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return String(localized: "\(total) 秒") }
        if total < 3600 { return String(localized: "\(total / 60) 分钟") }
        return String(localized: "\(total / 3600) 小时 \(total % 3600 / 60) 分")
    }

    /// 超过一小时显示 h:mm:ss，否则 mm:ss。
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 真实输入电平：五根竖条，不做装饰性动画。
struct LevelMeter: View {
    var level: Double
    var tint: Color = .red
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Double(index) / 5
                Capsule()
                    .fill(level > threshold + 0.02 ? tint.opacity(0.9) : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: 4 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 16)
        .accessibilityLabel(Text("输入电平"))
        .accessibilityValue(Text("\(Int(level * 100))%"))
    }
}

/// AppKit 毛玻璃；state 固定为 active，保证 App 不在前台时小窗仍是模糊背景。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material; view.blendingMode = blending; view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material; view.blendingMode = blending
    }
}

/// 窗口底部的短暂提示，可撤销；数秒后自动消失。
struct ToastOverlay: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(toast.text).lineLimit(2)
                    if let undo = toast.undo {
                        Button(toast.action ?? String(localized: "撤销")) { undo(); model.toast = nil }
                            .buttonStyle(.borderless).fontWeight(.semibold)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(toast.undo == nil ? 2.5 : 5))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: model.toast?.id)
    }
}

/// 横幅：用于需要用户知道、但不该打断的状态（错误、保存结果、缺少翻译资源）。
struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let text: String
    var detail: String? = nil
    var onClose: (() -> Void)? = nil
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout).textSelection(.enabled)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            actions.controlSize(.small)
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("关闭")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }
}

extension View {
    /// 按条件开启文字选择（两种可选性是不同类型，不能直接用三元表达式）。
    @ViewBuilder func selectableText(_ enabled: Bool) -> some View {
        if enabled { textSelection(.enabled) } else { textSelection(.disabled) }
    }

    /// 统一的次要圆角面板底色。
    func panelBackground(cornerRadius: CGFloat = 12) -> some View {
        background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 回答的简易排版：标题变成粗体行、列表加圆点或序号，行内粗体与引用链接照常。
/// SwiftUI 的 Text 不排版块级 Markdown，否则 `#`、`-` 会原样露出或挤成一行。
struct MarkdownBlocks: View {
    let source: String
    var font: Font = .callout

    private enum Block { case heading(String), bullet(String), numbered(String, String), paragraph(String) }

    private var blocks: [Block] {
        source.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.allSatisfy({ "-*_".contains($0) }) { return nil }
            if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) { return .bullet(String(line.dropFirst(marker.count))) }
            if let dot = line.firstIndex(of: "."), line[..<dot].count <= 2, line[..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                return .numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...]))
            }
            return .paragraph(line)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text): inline(text).font(font.weight(.semibold)).padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•").foregroundStyle(.secondary); inline(text) }
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(number).monospacedDigit().foregroundStyle(.secondary); inline(text) }
                case .paragraph(let text): inline(text)
                }
            }
        }
        .font(font)
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
