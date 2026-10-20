# Inline 邮件正文识别与历史邮件恢复

日期：2026-10-20。状态：已实现、合并并推送 main；本地服务已重启并验证首批 500 封恢复。下一授权步骤为发布 v0.6.6；公共生产部署与目标邮件验收尚未执行。执行记录见[实施计划](../plans/2026-10-20-mail-inline-body-recovery.md)。

## 问题与证据

用户提供的 Apple Developer 通知在生产 v0.6.5 显示 `(No readable body)`，下方出现两个名为 `attachment` 的下载项。
页面版本信息与本地基线均为 `e29fc6739267ddce6fa4c4b459efa4cb2a81f45f`。

只读 REST 查询确认：`text_body=null`、`has_html=false`；两个附件分别是 762 B 的 `text/plain` 和 7,293 B 的 `text/html`，两者 `disposition=inline`、`content_id=null`。正文 API 的 `html_body` 也是 null。附件 GET 返回完整、已解码的正文。

本地调用现有 `Manifold.Mail.Parser.parse/2`，用相同的 `multipart/alternative` 内容只改变 disposition，得到以下对照结果：

| 两个正文 part 的 disposition | text_body / html_body | 附件数 |
| --- | --- | --- |
| 未指定 | 均正常 | 0 |
| inline | 均为 nil | 2 |
| attachment | 均为 nil | 2 |

根因在 [parser.ex](../../../apps/manifold_mail/lib/manifold/mail/parser.ex)：`attachment?/1` 把所有 `inline` 都视为附件；`selected_bodies/1` 排除这些 part，附件提取却收集它们。读取界面按已保存的正文状态展示，因此没有创建 HTML iframe。当前证据指向本地角色判定，没有发现依赖缺陷。

尚未读取这封信的归档 raw MIME；完整父级 MIME 树和原始 filename 参数仍未核实。上述线上元数据、本地代码和最小复现足以确认 inline 正文误分类这条故障路径。

## 范围与成功标准

本轮修复正文识别，并使用归档 raw 重建已有邮件。HTML 样式、图片、CID 展示策略和 iframe 高度留到下一轮设计。

验收时，这封邮件应显示 HTML 正文，保留可供回复使用的纯文本正文，两个被误判的正文 part 不再出现在附件列表。真正附件与 inline 图片资源继续保留；邮件 ID、已读、星标、文件夹、会话归属和已校正的接收时间保持稳定。

现有 sanitizer、正文 CSP、iframe sandbox、跨邮箱隔离和 quarantine 规则保持现状。本轮只能承诺恢复当前清洗策略下的可读正文；原邮件的样式和图片仍会被移除。

## 方案比较

| 方案 | 代价与取舍 | 结论 |
| --- | --- | --- |
| 在现有 MIME 树选择中区分正文资格与附件收集，记录最终正文 part 路径 | 局部修改 parser；能避免选中正文重复作为附件，同时保留未选中的资源 | 推荐 |
| 仅从通用 attachment 判断中删除 inline | 改动少，但会混淆正文与 inline 资源，也不能完整处理带 filename 的 inline 正文 | 不采用 |
| 在 LiveView 将 text/html 或 text/plain 附件补作正文 | 重复 MIME 决策，可能误展示真实文件附件，保存的正文和回复来源仍错误 | 不采用 |

## 正文选择与附件规则

保留现有分支顺序：`multipart/alternative` 选择各类型最后一个正文候选；`multipart/related` 使用 `start` 指定根或第一个 part；`multipart/mixed` 等容器选择第一个有效正文分支。

在此基础上：

1. 显式 `Content-Disposition: attachment` 排除整个正文候选子树，即使其内容是 text/plain 或 text/html。
2. inline 的 text/plain、text/html 可以成为所在正文分支的候选；非空 filename 不否定显式 inline 的正文资格。
3. 未指定 inline 且带非空 filename 的文本 part 保留现有文件附件语义。先分别规范化 disposition 的 filename 和 content-type 的 name，再按 filename → name 回退，避免空 filename 掩盖有效 name。缺失、空字符串或全空白名称均视为无文件名；非空名称保留原值。
4. inline 图片和其他非正文类型不成为正文。related 的非根 sibling 也不会抢占正文。
5. 正文选择内部结果同时记录最终 text/html leaf 的 part_path；使用与现有附件提取相同的路径编号。无正文对应空路径，单 part 使用 `1`。alternative 覆盖候选时同步替换路径，不累积已经落选的路径。
6. 附件提取保留现有候选规则，再排除已被选为正文的路径。未选中的 inline 或有名 sibling 仍按原规则保留，避免误删下载资源。

路径只在 parser 内部传递，不改变 `ParsedMessage` 的公共结构。继续使用现有 MIME、字符集、大小、深度和超时边界，不引入新的解析依赖。

## 已有邮件恢复

[projector.ex](../../../apps/manifold_mail/lib/manifold/mail/projector.ex) 已支持从归档 raw 核验 size/hash 后，原位重建派生数据；[reconciler.ex](../../../apps/manifold_ingest/lib/manifold/ingest/reconciler.ex) 会给旧 parser/sanitizer 版本排队重投影。

实现已将 `parser_version` 从 5 升到 6，`sanitizer_version` 保持 1。部署后使用现有后台任务恢复旧投影，不重新拉取、导入或发送邮件。版本升级覆盖旧 parser 投影，不仅覆盖此封信；届时应记录待处理、成功、失败数量及失败原因。

先用回归样本验证“旧版错误投影 → 新版正文与附件结果”，再发布版本升级。公共生产部署后以用户提供的邮件为首个浏览器验收对象，并抽查纯文本、真实文本附件和 inline 图片邮件。用户已在实施完成后授权合并、提交推送、本地服务重启和下一版本发布；公共生产部署单独处理。

归档 raw 缺失、损坏或读取失败时，重建失败必须保留现有投影；解析失败也不能把原本有效的正文降级覆盖。现有 projector 支持 parse fallback，实施时需要为“旧版 parsed → 新版 fallback”增加明确的拒绝发布保护：在现有 delivery 锁内重新读取已保存投影后判断，避免并发重投影时使用过时的初读结果。首次投影的 fallback 语义保持现状。数据库写入失败继续使用现有原子事务保留旧投影。

上述拒绝替换分支返回临时类 Error，保留原始解析失败原因且不包含邮件原文。`Ingest.project_delivery/2` 的现有非 permanent 分支直接透传，`ProjectInboundMail` 使用现有 Oban 重试；已处理 delivery 的状态与已保存版本均不前进。不得让该保护走 permanent 分支并触发不合法的 `processed → failed` 转换。每个任务已有重试上限，但 reconciler 可能再次排队；仍需统计剩余旧版本和失败，不能宣称永久失败会自动恢复。

另一个必要保护位于 replacement 属性构建：当前 `mailbox_received_at/1` 对 provider_import 返回 nil，会清除同步后通过 INTERNALDATE/DateReceived 校正的时间。重投影必须保留已有 `received_at`，尤其是 provider_import；首次导入仍使用既有“随后由同步校正”的流程。

重投影保持 message 和 mailbox entry 身份及用户状态。现有流程会重建附件行，因此真正附件的旧下载 URL 可能失效；本轮保留这一既有行为，不增加附件身份迁移。raw 与 content-addressed blob 的清理策略不在本轮范围内。

## 受影响边界

| 文件 / 模块 | 本轮职责 |
| --- | --- |
| `apps/manifold_mail/lib/manifold/mail/parser.ex` | 正文资格、内部 part 路径与附件排除 |
| `apps/manifold_mail/lib/manifold/mail/projector.ex` | 拒绝失败重解析覆盖有效旧投影；替换时保留已校正接收时间 |
| `apps/manifold_mail/test/manifold/mail/parser_test.exs` | MIME 角色与分支选择回归 |
| `apps/manifold_mail/test/manifold/mail/projector_test.exs` | 旧数据修复、事务与用户状态保留 |
| `apps/manifold_ingest/test/manifold/ingest_test.exs` | 通过实际重投影入口验证失败原因和 delivery 状态保留 |
| `apps/manifold_web/test/manifold_web/mail_live_test.exs` | 已修复正文进入 iframe / plain 分支，附件列表正确 |
| `config/config.exs` | parser 版本升级，触发现有回填流程 |
| `.agents/skills/develop/references/mail-body-rendering.md` | 维护入口、实施状态和验收结果 |

不需要数据库迁移、新后台任务或 API 字段。前端生产代码目前没有已确认的修改需求。

## 验证设计

- Parser：单 part inline plain/html；inline alternative；inline 文本带 filename；空 filename；mixed 中的真正 txt/html 附件；related 根与 CID 图片；显式 attachment multipart 子树；既有无 disposition、字符集和容量限制回归。
- 路径一致性：单 part、嵌套 alternative/related/mixed，以及未选中的 inline sibling；正文不得同时出现在附件列表。
- Projector：先构造旧版空正文加两个 inline 附件，再用新版规则重建；验证相同 message ID、entry ID、已读、星标、文件夹、会话、接收时间，错误附件消失；失败保持旧数据；重复运行不重复建信。单独覆盖 provider_import 已校正 received_at 的保留。
- 失败保护：raw 不可读、解析失败/超时、事务失败均不破坏有效旧投影。经 `Ingest.project_delivery/2` 验证保护分支保留原解析原因、processed 状态及旧投影版本；首次解析失败仍按既有 fallback 处理。
- Reader：HTML 正文产生 iframe，纯文本正确转义，无正文才显示 fallback；保留现有正文/附件 CSP、邮箱归属和 quarantine 资源测试。
- 仅运行相关 parser、projector、ingest 重投影入口、邮件阅读和资源控制器测试；本轮不需要 CSS/JS 构建或全 umbrella 测试。范围外失败列出并停止，不扩展修复。
- 发布后以实际 API 字段、附件数与浏览器正文显示确认恢复；队列数量下降或日志中无错误不能单独作为恢复证明。

## 当前验证状态

PASS：线上页面复现、conversation/body/attachment 只读 API 检查、本地真实 Parser 最小对照；新增用例在修复前复现正文缺失、接收时间清空和失败重解析覆盖。

PASS：最终五个相关测试文件，seed 792712：mail 45、ingest 57、web 31，共 133 项，0 失败。覆盖本地旧投影重建、状态与身份保留、失败保护、阅读分支和已有资源安全测试。修改文件格式检查、test 环境严格编译和 diff whitespace 检查通过。

超时用例使用约 2 MiB 有效 raw 和零解析超时，严格断言 `parser_timeout`，没有重试或接受多种结果；这是实际 deadline 边界覆盖，不是与调度无关的时序证明。锁内重读用例通过现有回调改变状态，不宣称完成真实并发写入压力测试。

集成检查点：修复 `590556f` 已合并并推送 main；合并后 scoped suite seed 947535 共 133 项、0 失败，格式与严格编译通过。远端 CI、TLS 检查和全 umbrella ExUnit 通过，共 1,597 项、0 失败，无排除或跳过。

本地运行检查点（2026-10-20 15:38:37 UTC）：PostgreSQL 可连接，devenv 两项服务 ready，web 与 API health 均返回 200。首批 500 封成为 parser 6/parsed，旧版本数量由 39,497 降为 38,997；邮件与 entry 数量及身份、时间、用户状态聚合指纹保持不变。既有 251 封 fallback 未改变，另有两个 parser-6 任务处于 retryable；未等待全部恢复。

NOT RUN：实际公共生产 raw 重放、部署和生产恢复。原目标邮件不在本地数据库中，仍需公共实例部署后的 API 与浏览器验收。v0.6.6 发布是此检查点之后的授权步骤。

另记录既有问题：新资源角色用例发现 mail 0.5.2 的默认 us-ascii 与现有 Charset 回调可能改写二进制图片字节。本轮使用有效 ASCII SVG 验证资源角色与精确内容，未修改编码路径；二进制附件完整性需单独调查。

## 后续 HTML 保真议题

现有清洗器删除 style、所有图片及绝大多数布局属性。这封信的 HTML 有 1 个 style 块、24 个 style 属性、7 个 table、1 张远程图片；正文恢复后仍会失去这些布局与资源。下一轮单独设计安全 CSS、表格属性、CID/远程图片策略、正文主题与滚动体验。
