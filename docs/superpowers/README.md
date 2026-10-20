# 功能设计与执行记录索引

整理日期：2026-10-13。当前开发状态和待办见 [开发进度](../PROGRESS.md)，文档总入口见 [docs 索引](../README.md)。

这里保留功能设计（`specs/`）和当时的执行计划（`plans/`），用于追溯范围与实现决策。旧文件中的 `Approved for planning`、`[ ]`、目标版本、环境限制和 staging 状态可能只描述写作时的情况；**未勾选历史清单不等于当前功能未实现**。下表结合后续维护记录与当前代码归类，没有批量回填旧清单。

“已实现”表示有实现或后续验收记录，不表示全部真实服务验收已经通过，也不表示本次重新运行了测试。验收结果应读取链接记录的日期、范围及 `PASS` / `FAIL` / `NOT RUN` 限制；当前验收缺口统一维护在 [开发进度](../PROGRESS.md)。

## Calendar 修正与实施

- [2026-10-19 Calendar 重新审核与修正计划](plans/2026-10-19-calendar-local-first-correction.md)：已按批准方案实现独立本地日历、Google/iCloud 多目标、时间/重复事件及迁移审核；[当前操作说明](../CALENDARS.md)、[实施与验证证据](implementation/calendar-validation.md)、[维护记录](../../.agents/skills/develop/references/calendar-local-first-review.md)。真实两家服务联合验收单独标记为 NOT RUN。

## 近期实现

| 功能 / 当前归类 | 设计 | 执行计划 | 维护记录与验收入口 |
| --- | --- | --- | --- |
| Inline 邮件正文识别与历史邮件恢复：已实现，本地 133 项 scoped 测试通过；生产恢复尚未执行，HTML 保真单独设计 | [2026-10-20](specs/2026-10-20-mail-inline-body-recovery-design.md) | [2026-10-20](plans/2026-10-20-mail-inline-body-recovery.md) | [维护记录与验收](../../.agents/skills/develop/references/mail-body-rendering.md) |
| HTTP client 迁移：全部业务消费者使用 native Fetch，0.21.10 修复最终上游阻塞 | [2026-10-14](specs/2026-10-14-http-fetch-client-design.md) | [2026-10-14](plans/2026-10-14-http-fetch-client.md) | [当前客户端契约与验收](../HTTP_CLIENT.md)、[维护记录](../../.agents/skills/develop/references/http-client-migration.md) |
| Gmail 收件同步限流：已实现 | [2026-10-09](specs/2026-10-09-gmail-sync-rate-limiting-design.md) | [2026-10-09](plans/2026-10-09-gmail-sync-rate-limiting.md) | [Gmail 限流记录与验收](../../.agents/skills/develop/references/gmail-sync-rate-limiting.md)；真实采样不证明整邮箱同步完成 |
| iCloud 通讯录 / 日历导入：已实现，Account 双向方案继承并扩展 | [2026-10-09](specs/2026-10-09-icloud-contacts-calendars-design.md) | [2026-10-10](plans/2026-10-10-icloud-contacts-calendars.md) | [当前 iCloud 维护记录](../../.agents/skills/develop/references/icloud-contacts-calendars.md)、[验收与发布记录](../ICLOUD_ACCEPTANCE.md) |
| Account 所属 iCloud 双向同步：已实现；真实 Apple 写入验收仍有缺口 | [2026-10-10](specs/2026-10-10-account-icloud-bidirectional-design.md) | [2026-10-10](plans/2026-10-10-account-icloud-bidirectional.md) | [iCloud 维护记录](../../.agents/skills/develop/references/icloud-contacts-calendars.md)、[操作说明](../ICLOUD.md)、[验收记录](../ICLOUD_ACCEPTANCE.md) |

此前通讯录 / 日历工作台改版的实现边界、70 项历史 scoped 测试及浏览器验收见 [工作台维护记录](../../.agents/skills/develop/references/contacts-calendar-workspace.md)。其中 Calendar 的 Account 所属/单目标模型已由上面的 2026-10-19 修正方案取代；Contacts 保持原有流程。

## 历史执行计划

这些计划的清单大多没有回填。关联维护记录或测试入口用于定位后续实现；表内测试链接仅说明覆盖位置，不代表本次执行结果。

| 功能 / 当前归类 | 设计 | 执行计划 | 维护记录与验收入口 |
| --- | --- | --- | --- |
| Add account 向导：历史方案，产品入口已演进为 Account 与收件方式管理 | [2026-07-31](specs/2026-07-31-add-account-ui-design.md) | [2026-07-31](plans/2026-07-31-add-account-ui.md) | 无独立维护条目；后续 [Account / 收件方式设计](specs/2026-08-06-account-receive-methods-design.md)、[Account 页面测试](../../apps/manifold_web/test/manifold_web/account_live_test.exs) |
| Local mailbox 创建向导：历史方案，当前用户身份使用 Account | [2026-07-31](specs/2026-07-31-local-mailbox-creation-ui-design.md) | [2026-07-31](plans/2026-07-31-local-mailbox-creation-ui.md) | 无独立维护条目；后续 [Account 设计](specs/2026-08-06-account-receive-methods-design.md)、[Account 页面测试](../../apps/manifold_web/test/manifold_web/account_live_test.exs) |
| IMAP Account connector：已实现，早期 v1 清单保留 | [2026-08-05](specs/2026-08-05-imap-account-connector-design.md) | [2026-08-05](plans/2026-08-05-imap-account-connector.md) | 无独立 IMAP 维护条目；[ADR 0008](../adr/0008-imap-read-only-connector.md)、[连接测试](../../apps/manifold_connectors/test/manifold/connectors/imap_account_test.exs)、[TLS 边界与验收](../TLS_BACKENDS.md) |
| Connector 活动日志：已实现 | [2026-08-06](specs/2026-08-06-connectors-activity-logs-design.md) | [2026-08-06](plans/2026-08-06-connectors-activity-logs.md) | 无独立维护条目；[活动日志测试](../../apps/manifold_connectors/test/manifold/connectors/activity_log_test.exs)、[IMAP 活动测试](../../apps/manifold_connectors/test/manifold/connectors/activity_log_imap_test.exs) |
| 邮箱已读 / 未读与多选：已实现；Google / Microsoft 写回等属后续范围 | [2026-08-07](specs/2026-08-07-mailbox-read-unread-controls-design.md) | [2026-08-07](plans/2026-08-07-mailbox-read-unread-controls.md) | [行为与后续清单](../../.agents/skills/develop/references/mailbox-read-unread-controls.md)、[列表动作与测试入口](../../.agents/skills/develop/references/mail-list-actions.md) |
| 邮件同步按钮的 Oban 状态 UI：已实现 | [2026-08-07](specs/2026-08-07-mail-sync-button-oban-ui-design.md) | [2026-08-07](plans/2026-08-07-mail-sync-button-oban-ui.md) | [行为与边界](../../.agents/skills/develop/references/mail-sync-button-oban-ui.md)、[Mail LiveView 测试](../../apps/manifold_web/test/manifold_web/mail_live_test.exs) |
| Settings 左侧导航：已实现 | [2026-08-07](specs/2026-08-07-settings-left-nav-design.md) | [2026-08-07](plans/2026-08-07-settings-left-nav.md) | [当前导航 / 外观设置记录](../../.agents/skills/develop/references/settings-left-nav.md) |
| Account 禁用与异步本地删除：已实现；不删除远端数据 | [2026-08-10](specs/2026-08-10-account-disable-async-delete-design.md) | [2026-08-10](plans/2026-08-10-account-disable-async-delete.md) | [生命周期、操作与验收记录](../../.agents/skills/develop/references/account-actions.md) |
| 入站 SMTP 仅由 Edge 运行：已实现 | [2026-08-10](specs/2026-08-10-edge-only-smtp-runtime-design.md) | [2026-08-10](plans/2026-08-10-edge-only-smtp-runtime.md) | [运行边界与验收](../../.agents/skills/develop/references/edge-only-smtp-runtime.md) |
| SMTP 发件方式表单样式：已实现 | [2026-08-10](specs/2026-08-10-smtp-form-style-design.md) | [2026-08-10](plans/2026-08-10-smtp-form-style.md) | [样式维护与验证入口](../../.agents/skills/develop/references/smtp-send-method-form-style.md) |
| Gmail 收件 / 发件方式：已实现，真实服务验收与可选扩展单独记录 | [2026-08-11](specs/2026-08-11-gmail-receive-send-methods-design.md) | [2026-08-11](plans/2026-08-11-gmail-receive-send-methods.md) | [实现、staging 清单与后续](../../.agents/skills/develop/references/gmail-receive-send-methods.md)、[共享授权记录](../../.agents/skills/develop/references/gmail-shared-authorizations.md) |
| Microsoft 365 收件 / 发件方式：已实现；个人账户支持见后续设备登录记录 | [2026-08-11](specs/2026-08-11-microsoft-365-receive-send-methods-design.md) | [2026-08-12](plans/2026-08-12-microsoft-365-receive-send-methods.md) | [实现与验收矩阵](../../.agents/skills/develop/references/microsoft-365-receive-send-methods.md)、[后续限流记录](../../.agents/skills/develop/references/microsoft-sync-throttling.md) |
| OAuth provider Settings：已实现，凭证通过 Settings 管理 | [2026-08-18](specs/2026-08-18-oauth-provider-settings-design.md) | [2026-08-18](plans/2026-08-18-oauth-provider-settings.md) | [维护与历史验收](../../.agents/skills/develop/references/oauth-provider-settings.md)、[当前 OAuth 配置](../OAUTH_SETUP.md) |
| Microsoft OAuth 采用 provider Settings：已实现；后续新增设备登录 | [2026-08-27](specs/2026-08-27-microsoft-oauth-provider-settings-design.md) | [2026-08-27](plans/2026-08-27-microsoft-oauth-provider-settings.md) | [维护与 2026-08-28 历史验收](../../.agents/skills/develop/references/oauth-provider-settings.md)、[设备登录记录](../../.agents/skills/develop/references/microsoft-device-oauth.md) |

## 无独立执行计划的设计

| 功能 / 当前归类 | 设计 | 维护记录与验收入口 |
| --- | --- | --- |
| Account 替代用户可见 Mailbox，管理多个收件方式：已实现 | [2026-08-06](specs/2026-08-06-account-receive-methods-design.md) | [收件方式添加 / 移除](../../.agents/skills/develop/references/receive-method-remove.md)、[Account 生命周期](../../.agents/skills/develop/references/account-actions.md)、[Account 页面测试](../../apps/manifold_web/test/manifold_web/account_live_test.exs) |
| Microsoft 设备登录与 OAuth 指引：已实现，个人账户登录 / 收件有真实记录 | [2026-10-06](specs/2026-10-06-oauth-device-login-design.md) | [设备登录验收与剩余真实服务缺口](../../.agents/skills/develop/references/microsoft-device-oauth.md)、[Google 粘贴回调完成](../../.agents/skills/develop/references/google-oauth-callback-paste.md)、[当前配置说明](../OAUTH_SETUP.md) |

## 如何维护状态

- 新的执行计划记录自己的任务完成和验收结果，历史文件保留原始决策。
- 功能行为改变时更新对应 `.agents/skills/develop/references/` 条目；在本索引链接取代旧方案的新设计。
- 将仍需实施的任务、上游依赖和真实服务验收缺口放入 [开发进度](../PROGRESS.md)，避免从历史 `[ ]` 自动生成当前待办。
- 历史测试、发布或后台同步样本不代表当前部署状态；需要实时判断时重新核实对应服务。
