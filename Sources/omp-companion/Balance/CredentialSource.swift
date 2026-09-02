import Foundation

/// 来自偏好面板的 provider API key 来源。由 `SettingsStore`（偏好面板）实现，
/// 避免 Balance 层依赖 UI 类型。
///
/// 键名沿用 `.env` 时代的变量名作为映射键（`DEEPSEEK_API_KEY` 等），
/// 使 `MiniMaxRemainsProvider.credentialKey` 等既有抽象保持不变。
public protocol CredentialSource: Sendable {
    /// 解析某个鉴权 key（以旧 `.env` 变量名作为映射键）；空 / 全空白视为缺失。
    func resolve(_ name: String) -> String?
}
