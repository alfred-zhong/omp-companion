import AppKit
import Foundation

/// 状态栏 logo 查表:ProviderID → NSImage。资源全部在 `.app/Contents/Resources/` 下,
/// 由 `build.sh` 在拼 .app 时统一从 `Resources/*.png` 复制过去。
///
/// `image(for:)` 加载时一次性 `setTemplate(true)`,使 AppKit 按系统 menu bar
/// 灰度重新着色(dark/light 自动跟随)。
///
/// Bundle URL 解析坑:`Bundle.main.url(forResource:withExtension:)` 对 `@2x`/`@3x`
/// scale suffix 不会自动匹配;`.app` 进程里 `bundlePath` 不是 `.app/Contents/...` 而是 `.app` 本身,
/// 唯一可靠的查找路径是 `Bundle.resourcePath`(.app/Contents/Resources)。
public enum LogoCatalog {

    /// `.minimax` 与 `.minimaxCodeCN` 复用同一张 logo(品牌一致)。
    private static func assetBaseName(for id: ProviderID) -> String {
        switch id {
        case .deepseek:        return "provider_deepseek"
        case .minimax,
             .minimaxCodeCN:  return "provider_minimax"
        case .opencodeGo:      return "provider_opencode_go"
        case .unknown:         return "logo_unknown"
        }
    }

    /// 在给定 bundle 里查 logo,命中后立即标记为 template。未命中返回 nil。
    /// 调用方约定把同一个 NSImage 缓存到 StatusBarController 自己的字段,避免每次刷新触发 I/O。
    public static func image(for id: ProviderID, bundle: Bundle = .main) -> NSImage? {
        let base = assetBaseName(for: id)
        // 1) 走标准 Bundle API。把 @2x/@3x 剥掉,因为 url(forResource:) 不识别 scale suffix;
        //    NSImage 自动按主屏 backing 选最匹配的 NSImageRep。
        for name in scaleCandidates(base: base) {
            let stripped = dropScaleSuffix(name)
            if let url = bundle.url(forResource: stripped, withExtension: "png")
                       ?? bundle.url(forResource: stripped, withExtension: "png", subdirectory: "Resources"),
               let img = NSImage(contentsOf: url) {
                img.setValue(true, forKey: "template")
                return img
            }
        }
        // 2) fallback:直接拼到 Bundle.resourcePath(.app/Contents/Resources)。
        guard let resourceDir = bundle.resourcePath else { return nil }
        for name in scaleCandidates(base: base) {
            let path = URL(fileURLWithPath: resourceDir).appendingPathComponent(name + ".png").path
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOf: URL(fileURLWithPath: path)) {
                img.setValue(true, forKey: "template")
                return img
            }
        }
        return nil
    }

    private static func scaleCandidates(base: String) -> [String] {
        let scale: Int = {
            if let s = NSScreen.main?.backingScaleFactor, s > 0 { return Int(s.rounded()) }
            return 2
        }()
        return scale >= 3 ? ["\(base)@3x", "\(base)@2x", base] : ["\(base)@2x", "\(base)@3x", base]
    }

    private static func dropScaleSuffix(_ name: String) -> String {
        for suffix in ["@3x", "@2x", "@1x"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// 给 SelfCheck 用:直接校验"catalog 能为每个 id 拿到 image"。
    /// `swift run` 下 Bundle.main 不带 Resources,所以 SelfCheck 用仓库绝对路径走 NSImage(contentsOf:)。
    public static func debugAssertsAvailable(bundle: Bundle) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for id in ProviderID.allCases {
            out[String(describing: id)] = image(for: id, bundle: bundle) != nil
        }
        return out
    }
}
