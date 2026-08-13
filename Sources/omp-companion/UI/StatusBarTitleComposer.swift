import AppKit
import QuartzCore

/// 纯函数：把余额文本 + 守护状态组装成状态栏标题。
/// 守护激活时前缀 `☕️ ` 用咖啡色着色；否则走纯文本。
public enum StatusBarTitleComposer {
    /// 咖啡色近似值 (#8B5A2B)。
    public static let caffeinateColor = NSColor(
        calibratedRed: 0x8B / 255.0,
        green: 0x5A / 255.0,
        blue: 0x2B / 255.0,
        alpha: 1.0
    )

    public static let clearColor = NSColor.clear

    /// 状态色块背景过渡时长；macOS Control Center 模块同区间。
    public static let chromeAnimationDuration: CFTimeInterval = 0.2

    /// `caffeinateActive == true`：在前面加 `☕️ ` 着色前缀。
    /// 返回 `NSAttributedString`，可直接赋给 `NSButton.title`。
    public static func compose(
        balanceText: String,
        isStale: Bool = false,
        caffeinateActive: Bool = false
    ) -> NSAttributedString {
        let body = balanceText + (isStale ? "·off" : "")
        let result = NSMutableAttributedString()
        if caffeinateActive {
            let prefix = NSAttributedString(
                string: "\u{2615} ",
                attributes: [.foregroundColor: caffeinateColor]
            )
            result.append(prefix)
        }
        result.append(NSAttributedString(string: body))
        return result
    }

}
