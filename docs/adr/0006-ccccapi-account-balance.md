# 0006 — ccccapi 余额使用网页 access token，按 10:1 展示人民币

ccccapi 是独立 Provider：仅当 `modelRoles.default` 使用 `ccccapi/*` 时，以 `.env` 链中的 `CCCCAPI_ACCESS_TOKEN` 调用 `GET https://ccccapi.cc/api/v1/user/profile`。该 token 是网页会话凭据而非 `sk-...` 模型 API Key；响应只接受标准成功 envelope 的 `data.balance`，内部按 USD 保存，展示按 `$10 = ¥1` 转为 CNY，不解析、保存或展示账户身份、API Key 和订阅资料。

## Context

ccccapi 是 sub2api 系列的网关。其资料接口使用网页登录 bearer token，而模型调用 API Key 不能查询账户余额。接口响应含用户资料与潜在敏感字段，且余额字段没有自描述币种；站点将此账户余额定义为 USD。

## Considered Options

1. 使用模型 API Key 或读取/展示完整用户资料——凭据语义不匹配，且扩大敏感数据范围。
2. 将余额作为 CNY、百分比配额或无单位数值——会错误表达 ccccapi 的 USD 账户余额来源语义。
3. 仅解析网页 token 的标准成功 envelope 中的 `data.balance`，并在展示边界按 10:1 转换——最小化权限与数据暴露，同时满足菜单栏人民币展示。

## Consequences

- token 必须由用户手动放入 `.env`；不会读取 Keychain、agent.db 或其他 omp 私有凭据存储。
- 空白 token 视为缺失；响应 envelope、`data.balance` 或数值语义异常时查询失败，绝不展示伪造的 `¥0.00`。
- 成功余额内部仍是 USD；状态栏和菜单按 `$10 = ¥1` 显示 CNY，保留两位小数。
- 请求失败、鉴权失败或业务响应失败时清除旧余额，状态栏与菜单显示 `NaN`，菜单同时保留具体错误原因。
- 已暴露的网页登录 token 必须由用户撤销或轮换。
