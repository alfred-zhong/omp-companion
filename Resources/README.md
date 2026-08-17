# Resources/

`build.sh` 把这里所有 `*.png` 平铺复制到 `omp-companion.app/Contents/Resources/`。

## 供应商 logo

资产为 **template 蒙版**（黑透 PNG → `setTemplate(true)`）。运行时由 `LogoCatalog` 集中查表 + 一次性打开，做 `setTemplate(true)` 后交给 `NSStatusItem.button.image`。

| 文件名 | 含义 |
|---|---|
| `provider_deepseek@2x.png` / `provider_deepseek@3x.png` | DeepSeek（32×32 / 48×48） |
| `provider_minimax@2x.png` / `provider_minimax@3x.png` | MiniMax Token Plan 与 MiniMax Coding Plan 复用（32×32 / 48×48） |
| `logo_unknown@2x.png` / `logo_unknown@3x.png` | ProviderID 路由不到（`.unknown`）时的默认问号蒙版 |

## 来源

| 资产 | 来源 | 时间 |
|---|---|---|
| DeepSeek | `https://cdn.deepseek.com/platform/favicon.png` | 2026-08-17 拉取 |
| MiniMax | 官网导航栏 logo：`https://filecdn.minimax.chat/public/969d635c-cab6-45cc-8d61-47c9fe40c81f.png`（裁剪图形区 x 0-152 / y 0-129，官方红色 "M" 字形，非 lobe-icons 变体） | 2026-08-17 重新制作 |

## 重新生成蒙版

`/tmp/render_logo.sh`（仓库外）会：

1. `curl` 拉原图到 Resources/*.color.png；
2. `sips` 缩放到 32 / 48 px；
3. `swift /tmp/make_template.swift` 把彩色版本转成黑透蒙版（alpha = 原图亮度）；
4. `swift /tmp/make_unknown.swift` 渲染 `?` 默认资产。

如换 logo，仅需：替换原图 → 重跑脚本 → 提交新 PNG。

## 不放的内容（明确取舍）

- 不缓存到 `~/Library/Caches/<bundle-id>/`：会与 ADR-0004 冲突。
- 不在 build 时下运行时 URL：开发机离线、CI 不可达；且 logo 是相对稳定的品牌资产。
- 不放进 SwiftPM `resources:`：现有 `build.sh` 已手工 `cp Resources/Info.plist`，保持单一 bundle 拼装路径。
