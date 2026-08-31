# Resources/

`build.sh` 把这里所有 `*.png` 与 `*.svg` 平铺复制到 `omp-companion.app/Contents/Resources/`。

## 状态栏 logo

运行时由 `LogoCatalog` 集中加载并标记为 template。DeepSeek / MiniMax / OpenCode Go 使用黑透 PNG 蒙版；ccccapi 与未匹配 Provider 使用 SVG 图标。

| 文件名 | 含义 |
|---|---|
| `provider_deepseek@2x.png` / `provider_deepseek@3x.png` | DeepSeek（32×32 / 48×48） |
| `provider_minimax@2x.png` / `provider_minimax@3x.png` | MiniMax Token Plan 与 MiniMax Coding Plan 复用（32×32 / 48×48） |
| `logo_omp.svg` | ProviderID 路由不到（`.unknown`）时使用的 omp 官方图标 |
| `provider_ccccapi.svg` | ccccapi 使用的 Sub2API SVG logo（构建时随 app 本地打包） |

## 来源

| 资产 | 来源 | 时间 |
|---|---|---|
| DeepSeek | `https://cdn.deepseek.com/platform/favicon.png` | 2026-08-17 拉取 |
| MiniMax | 官网导航栏 logo：`https://filecdn.minimax.chat/public/969d635c-cab6-45cc-8d61-47c9fe40c81f.png`（裁剪图形区 x 0-152 / y 0-129，官方红色 "M" 字形，非 lobe-icons 变体） | 2026-08-17 重新制作 |
| omp | 用户提供的 omp 官网 `pi-mark-2` SVG | 2026-08-28 更新 |
| ccccapi | `https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/assets/logo.svg`（Sub2API upstream asset，本地提交） | 2026-08-31 |

## 重新生成 Provider PNG 蒙版

`/tmp/render_logo.sh`（仓库外）会：

1. `curl` 拉原图到 Resources/*.color.png；
2. `sips` 缩放到 32 / 48 px；
3. `swift /tmp/make_template.swift` 把彩色版本转成黑透蒙版（alpha = 原图亮度）。

替换 Provider logo 后，重跑脚本并提交新 PNG。`logo_omp.svg` 保留上游官方源文件，不参与该转换。

## 不放的内容（明确取舍）

- 不缓存到 `~/Library/Caches/<bundle-id>/`：会与 ADR-0004 冲突。
- 不在 build 时下运行时 URL：开发机离线、CI 不可达；且 logo 是相对稳定的品牌资产。
- 不放进 SwiftPM `resources:`：现有 `build.sh` 已手工 `cp Resources/Info.plist`，保持单一 bundle 拼装路径。
