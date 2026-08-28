import AppKit
import Foundation

/// 下拉菜单里的用量进度条行：左窗口标签 + 中进度条 + 紧贴条尾的百分比 + 右侧左对齐的重置倒计时。
/// 仅用于 `MenuItemSpec.usageBar`，由 `StatusBarController.installItem` 装配。
///
/// 布局（来自 grill 敲定 + 目检修订）：
/// ```
/// 5h [████░░░░░░] 0%  3h56m 后重置
/// ```
/// - 左半部分：`5h [进度条] 0%`——标签右对齐定宽 40pt；百分比区定宽 40pt（容纳 `100%`），
///   百分比左对齐紧贴条尾，进度条长度不随百分比位数变化，多行条长一致（中间无 `·`）。
/// - 右半部分：`3h56m 后重置`——定宽区**左对齐**（右侧不右对齐，倒计时文本长短不一
///   时右缘参差可接受），无倒计时（nil/空）时该区留白，进度条可拉长。
/// - 进度条最短 `minBarWidth`(60pt)：视图宽度以 240pt 为底、按需加宽到
///   `minimumWidth(hasLeftLabel:)`，保证窄菜单里条长不缩成短条（由 `init` 保证）。
///
/// 其余约束：
/// - view 设 `.width`，菜单自动拉满宽；行高由 `intrinsicContentSize`(20) 固定，
///   否则 view-based 菜单项会因 intrinsic 高度为 0 而塌成空行。
/// - 背景透明，选区由菜单原生绘制；高亮时仅把文本翻白。
/// - 三段色：<70 绿 / 70–90 黄 / >90 红（满=告急）；`rateLimited` 状态不影响颜色。
/// - `value` 已由 Presenter clamp 到 [0,100]；这里再次防御性 clamp。
///
/// 注：`NSProgressIndicator` 在本 SDK 无 `contentTintColor`，三段色无法靠 tint 实现，
/// 故进度条直接绘制（圆角轨道 + 段色填充）。无子视图，全部在 `draw(_:)` 内完成，
/// 规避菜单项子视图渲染不稳的问题。
final class UsageBarMenuItemView: NSView {
    private let leftText: String?
    private let value: Double
    private let percentText: String
    private let resetText: String?
    private let fill: NSColor

    /// 布局常量（pt）：外边距 / 左标签定宽 / 标签-条-文本间隙 / 百分比区定宽 / 重置倒计时区定宽 / 条高 / 进度条最短长。
    private static let margin: CGFloat = 6
    private static let leftWidth: CGFloat = 40
    private static let gap: CGFloat = 8
    private static let percentRegionWidth: CGFloat = 40
    private static let resetRegionWidth: CGFloat = 100
    private static let barHeight: CGFloat = 10

    /// 进度条最短长度（pt）：视图宽度不足时通过加宽自身保证，避免窄菜单里条太短。
    static let minBarWidth: CGFloat = 60

    init(leftText: String?, value: Double, percentText: String, resetText: String?) {
        let clamped = min(max(value, 0), 100)
        self.leftText = leftText
        self.value = clamped
        self.percentText = percentText
        self.resetText = resetText
        self.fill = Self.segmentColor(for: clamped)
        let hasLeftLabel = !(leftText?.isEmpty ?? true)
        let width = max(240, Self.minimumWidth(hasLeftLabel: hasLeftLabel))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        self.autoresizingMask = .width
    }

    /// 保证进度条 ≥ `minBarWidth` 所需的最小视图宽：
    /// 外边距×2 + 左标签区 + 三处间隙 + 最短条 + 百分比区 + 重置区。视图默认 240pt，不足时加宽到该值。
    static func minimumWidth(hasLeftLabel: Bool) -> CGFloat {
        margin * 2 + (hasLeftLabel ? leftWidth : 0) + gap * 3 + minBarWidth + percentRegionWidth + resetRegionWidth
    }

    /// 给定总宽下的进度条长度（与 `draw` 同一公式，供 SelfCheck 断言最小长度不变量）。
    static func barWidth(totalWidth: CGFloat, hasLeftLabel: Bool) -> CGFloat {
        let barX = margin + (hasLeftLabel ? leftWidth : 0) + gap
        return max(0, totalWidth - margin - barX - gap - percentRegionWidth - gap - resetRegionWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        let labelColor: NSColor = highlighted ? .white : .labelColor
        let font = NSFont.menuFont(ofSize: 0)
        let attr: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
        ]

        // 百分比先测量：进度条长度 = 剩余宽 - 百分比宽 - 重置区宽，百分比紧贴条尾。
        let percent = NSAttributedString(string: percentText, attributes: attr)
        let percentSize = percent.size()

        // 左标签（右对齐在固定宽度区内；nil/空 → 宽度收缩为 0）
        var leftRegionWidth: CGFloat = 0
        if let left = leftText, !left.isEmpty {
            leftRegionWidth = Self.leftWidth
            let text = NSAttributedString(string: left, attributes: attr)
            let size = text.size()
            text.draw(at: NSPoint(x: Self.margin + Self.leftWidth - size.width, y: (bounds.height - size.height) / 2))
        }

        // 进度条 + 紧贴的百分比：左标签区之后，右区之前。
        // 百分比区定宽（容纳 "100%"），进度条长度不随百分比位数变化，三行条长一致。
        let barX = Self.margin + leftRegionWidth + Self.gap
        let barW = Self.barWidth(totalWidth: bounds.width, hasLeftLabel: leftRegionWidth > 0)
        if barW > 0 {
            let barY = (bounds.height - Self.barHeight) / 2
            let radius = Self.barHeight / 2
            let trackColor: NSColor = highlighted
                ? NSColor.white.withAlphaComponent(0.25)
                : NSColor.separatorColor
            let trackPath = NSBezierPath(
                roundedRect: NSRect(x: barX, y: barY, width: barW, height: Self.barHeight),
                xRadius: radius, yRadius: radius
            )
            trackColor.setFill()
            trackPath.fill()

            if value > 0 {
                let fillW = min(barW, max(radius * 2, barW * (value / 100)))
                let fillPath = NSBezierPath(
                    roundedRect: NSRect(x: barX, y: barY, width: fillW, height: Self.barHeight),
                    xRadius: radius, yRadius: radius
                )
                fill.setFill()
                fillPath.fill()
            }
        }
        // 百分比：左对齐在定宽区内，紧贴条尾（右缘随位数参差，可接受）
        percent.draw(at: NSPoint(x: barX + barW + Self.gap, y: (bounds.height - percentSize.height) / 2))

        // 重置倒计时：右区左对齐（无倒计时则留白）
        if let resetText, !resetText.isEmpty {
            let reset = NSAttributedString(string: resetText, attributes: attr)
            let resetSize = reset.size()
            reset.draw(at: NSPoint(x: bounds.width - Self.margin - Self.resetRegionWidth, y: (bounds.height - resetSize.height) / 2))
        }
    }

    private static func segmentColor(for value: Double) -> NSColor {
        if value > 90 { return .systemRed }
        if value >= 70 { return .systemYellow }
        return .systemGreen
    }
}
