# 协作命令与任务数据

公共入口使用 PowerShell 7.4+。在 Windows 或 macOS 上运行时采用相同的命令与角色流程：

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Status
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Doctor
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 <Command> -RequestFile <request.json> -Actor coordinator
```

可通过 `-Root` 指定项目绝对路径；默认根据脚本位置定位项目。模块入口为 `Invoke-CollabCommand -Command <name> -Root <root> -Request <hashtable> -Actor coordinator`。

结果为 JSON，成功时 `Ok=true`、退出码 0；具体结果查看 `Code` 与证据路径。

## 命令

| 命令 | 请求内容与作用 |
|---|---|
| `Status` | 可选 TaskId；返回任务、Revision、PlanRevision、当前 DiffDigest、PlanSha256、锁、违规及清理标记 |
| `Doctor` | 返回项目状态、工具入口解析和配置偏好 |
| `NewTask` | TaskId、Grade、GradeReason、Authorization、Acceptance、AllowedPath；可选 TesterWritePath、FrozenTest、PlanFile、RequiresRealWorkflow、Maintenance、Notes |
| `Backup` | TaskId；备份具名文件和原始元数据，记录不存在的文件 |
| `Advance` | TaskId、To、Reason；按阶段条件推进任务 |
| `Invoke` | TaskId、Tool、Role、InstanceId、ExpectedDigest；PromptFile 或 ContextId 二选一，可选 ExpectedRevision；executor 提供非空 WritePaths，tester 按需提供；重要任务的 executor/tester 提供 ExpectedPlanSha256；reviewer 提供 SubjectKind 与 ExpectedSubjectSha256 |
| `RecordReview` | TaskId、SubjectKind、Verdict、InvocationId、ArtifactPath、ExpectedSubjectSha256、Findings；有细节问题时提供 Adjudication |
| `RecordAcceptance` | TaskId、AcceptanceId、Status、EvidencePath、Kind、Note；Status 为 pending/failed/passed，真实流程使用 Kind=real_workflow |
| `Complete` | TaskId、Reason；协调者核验后签署完成 |
| `Handoff` | TaskId、ExpectedDigest、Reason；核验当前失败的范围与清理，保存交接边界、重置验收并切换续作阶段 |
| `ProbeTool` | Tool；执行配置的本地版本/能力检查并记录证据 |
| `Rework` | TaskId、ExpectedRevision、ExpectedDigest、Reason；可选 PlanFile 或 ReuseImplementationFrom；在同一任务内开始新修订 |
| `PrepareContext` | TaskId、Role、ExpectedRevision、ExpectedDigest、PromptFile；可选 References、PriorInvocationIds、Delta；返回 ContextId |
| `RecoverTask` | TaskId、ExpectedRevision、ExpectedDigest、InvocationIds、ViolationIds、EvidencePath、EvidenceSha256、Reason、ProcessVerification、FileVerification；核验异常处理并返回 Rework |
| `RecoverLock` | LockToken、Reason、Confirm；根据记录核验原 owner 和调用进程，再执行锁恢复 |

请求模板位于 [templates](templates/)。任务、调用、审查、验收及文件库存保存在项目 `.collaboration/`。

`new-task.json` 和 `invoke.json` 展示普通任务；重要任务在创建请求中设置 `Grade=important` 并提供 `PlanFile`，方案正文可使用 `plan.md`。`review.json` 展示重要任务的方案审查登记。模板中的任务 ID、文件路径、摘要与调用 ID 按同一实际任务填写。

`rework.json` 中 ReuseImplementationFrom 默认为空，采用完整返工；本轮仅需验证或修改测试文件时，可按下文条件填写有效实现调用 ID。

`RequiresRealWorkflow` 按验收要求设置：需要真实用户流程时设为 true，并用 `RecordAcceptance` 的 `Kind=real_workflow` 登记实际证据和操作者验证说明。

## 执行顺序

普通任务：NewTask → Backup → Advance implementing → Invoke executor → Advance validating → Invoke tester → RecordAcceptance → Complete。

重要任务：NewTask 时保存方案；先 Invoke reviewer（SubjectKind=plan）→ RecordReview → Advance plan_reviewed，然后进入实现和测试。完成测试后 Invoke reviewer（SubjectKind=result）→ RecordReview → Advance result_reviewed，再签署完成。

NewTask 的 TesterWritePath 是 AllowedPath 的具名子集，保存为创建时角色边界；执行者写其余任务文件，测试者只写指定测试文件或测试产物。省略时测试者仅执行检查。冻结测试保持原件；新增测试写入范围在创建任务时声明。

角色边界同时检查别名冲突和具名授权。macOS 根据已有文件身份识别角色冲突，后置范围及恢复核验按父目录、文件名与所在文件系统规则判断授权；新增硬链接使用自己的具名范围。Windows 对路径按不区分大小写的范围判断。控制快照分别保留大小写不同文件的摘要。

每次 Invoke 使用新 InstanceId。tester 与 executor 使用独立实例，reviewer 与实现/测试实例分开。文件范围采用具名路径，例如 `src/order.ts`；路径大小写与实际文件一致。

上面的 `Advance implementing`、`Invoke executor` 表示操作及请求字段，分别对应 JSON 中的 `To` 与 `Role`。实际命令通过 `-RequestFile` 读取这些字段。普通任务和重要任务均在完成前逐项执行 RecordAcceptance。

## 审查协议

审查输出最后非空行采用三种裁决之一：`COLLAB_VERDICT: PASS`、`COLLAB_VERDICT: PASS WITH NITS`、`COLLAB_VERDICT: FAIL`。

RecordReview 绑定实际调用产物及当前被审摘要。Findings 中的 ID 非空且在本次审查内唯一；同一问题在交接中沿用 ID，回传处理结论与证据，由协调者登记独立复验结果。PASS WITH NITS 需要具体 Findings 与协调者逐项 Adjudication。记录 FAIL 后任务进入 blocked，通过 Rework 开始新修订并重新审查。测试、验收与结果审查均绑定当前 revision；执行采用当前修订记录或有效的实现沿用记录；方案审查绑定 planRevision 和方案摘要。验收时重新核对当前实现、有效测试、审查与证据。

## 配置模型工具

工具表为 `{ "schemaVersion": 1, "preferenceOrder": [], "tools": [] }`。每个工具条目包含：

- `id`、`label`、`kind`、`enabled`、`readiness`。
- `executable`、`resolve`、`commonArgs`、`roleArgs`、`nonGitArgs`、`env`。
- `requestedModel`、`observedModel`、`reasoningEffort`、`allowedRoles`、`notes`。
- 固定入口的 `probeArgs` 与可选 `probeContains`。

`id` 为用户自定义名称；模型与调用顺序由项目选择。`kind=json` 使用通用结果协议；运行时也包含 claude、codex、zcode、grok 的 CLI 参数/输出适配器。各工具 CLI 参数按实际安装版本配置。

`requestedModel` 在 Claude/Codex 协议中构造模型参数，空值时由 CLI 配置决定；在 JSON 协议中替换 `{model}`，适配器负责空值处理；在 ZCode/Grok 协议中记录预期，实际模型通过 CLI 配置或 commonArgs 选择。`reasoningEffort` 和 `nonGitArgs` 用于 Codex 协议；ZCode 另需 entryScript。

通用参数整项支持 `{promptFile}`、`{prompt}`、`{role}`、`{model}`、`{cwd}`、`{resultFile}`。适配器以 UTF-8 读取提示文件，启动本次独立工作会话，完成后以退出码 0 和单个 stdout JSON 对象返回：

```json
{"schemaVersion":1,"ok":true,"final":"实际产物与证据","session":{"id":"实际会话ID","fresh":true},"readOnly":false}
```

可选 `model` 报告实际模型；reviewer/probe 对应 `readOnly=true` 和真实只读工具能力，同时返回 `toolAuditComplete=true` 与 `toolEvents` 数组。每项事件为 `{"type":"tool_call","name":"read_file","access":"read"}`；未调用工具时使用空数组。适配器按实际工具能力归类事件，运行时核对结构与只读能力。审查裁决位于 `final` 最后非空行。

JSON 协议的实际会话标识采用“服务身份＋会话 ID”，同一服务的工具别名沿用相同服务身份，运行时跨工具核对历史复用。所有协议记录 InstanceId 并要求新会话；原生 CLI 的会话参数与原始日志由协调者在接入和派发时核实，实际会话 ID 的自动复用检查仍待补齐。

固定入口的 `ProbeTool` 使用 probeArgs 检查本地版本或帮助，记录退出码、输出与清理，绑定执行文件、参数中的脚本摘要和角色配置；相对路径按项目根目录解析。JSON 协议在 Invoke 前核对该指纹。Codex 目录发现检查候选二进制的版本与 exec 帮助，按二进制摘要、探测时间和兼容性结果绑定。

接入时先执行 ProbeTool，再在独立验证项目中将测试配置设为 enabled=true、readiness=ready，运行隔离任务验证实际角色能力。通过后将本项目配置登记为 enabled=true、readiness=ready，并重新执行 ProbeTool。配置变化后按影响范围重新验证。

`Invoke` 的 probe 是模型参与的只读任务，与 ProbeTool 命令分别使用；它同样需要 TaskId、独立 InstanceId、提示文件与已就绪配置。

## 角色上下文与交付

PrepareContext 根据 PromptFile 的本轮说明、Delta、References 文件列表与 PriorInvocationIds 生成角色交接包。背景与源码保留路径引用及 SHA256；验收要求、当前修订、角色重点和前序调用入口集中呈现。Invoke 使用 ContextId 时核对角色、修订、实现摘要及全部引用。源文件变化后重新 PrepareContext。

派发以本次角色的完整交付为单位，包含验收依据和阻断条件。工作实例完成相关工作及检查后，回传结果、命令与退出码、关键证据及未解决事项。复查围绕相关改动、失败或证据冲突展开，完整日志通过路径引用。

协调者按 [项目修复阈值](../../COLLABORATION.md#修复阈值与停止条件) 记录同一问题的尝试和验证结果：连续两轮无实质进展时停止相关自动派发，说明阻断原因、两轮证据和继续所需条件，按用户明确的继续指示恢复。Handoff、Rework、更换模型和关联任务均延续原问题记录。非阻断建议记录裁决或待办，不触发返工。进展判断由协调者执行，命令门禁继续核验各阶段的质量证据。

## 返工与进程管理

Handoff 核对当前修订失败调用的范围、控制文件和清理检查。仍待接续的执行者失败使任务进入 implementing，其他情况已有 accepted executor 或有效实现沿用记录时进入 validating，否则进入 implementing。协调者在 Reason 中说明失败处理与后续工作。范围、控制文件或清理异常通过 RecoverTask 后采用完整 Rework。

Handoff 在 task.continuation 中保存交接前的调用、验收、审查 ID 和失败原件摘要，并将验收设为 pending、重置真实流程验证与签署。连续交接时，每条失败可附 replacement，绑定成功接续调用 ID 与原件摘要；reviewer 另绑定审查记录 ID 和摘要。运行时核验当前修订、方案、结果原件及对应文件摘要：executor 使用实现摘要，tester / probe 使用全部任务文件摘要，reviewer 使用相同 SubjectKind 的摘要。有效接续继续使用，待处理失败由相应角色的新实例完成。交接摘要的 failureResolutions 列出已保留接续调用和待处理项。

每次交接后取得当前摘要的独立测试和新验收；重要任务还取得交接后的结果审查。Complete 和后续 ReuseImplementationFrom 共同检查这些条件。续作满足条件后直接 Complete 当前修订；尚未 Complete 且有具体的新一轮修复目标时才 Rework，已完成任务的新问题创建关联任务。交接后再次发生普通调用失败，可重新 Handoff；需要完整实施修复时采用默认 Rework。

Handoff 与 Rework 共同采用有效恢复证据判断历史清理状态，原始调用的清理标签持续保留。

测试或审查发现实现问题时，读取 Status 后提交 Rework。任务保留 ID、目标、等级和文件范围，revision 递增，上一轮验收与真实流程验证重置；历史备份、调用与证据保存原件。方案仍有效时默认进入 implementing，依次实现、独立测试及必要结果审查。提交 PlanFile 时更新 planRevision 并回到 planned，重要任务先重新完成方案审查。目标、等级或范围改变时创建关联任务。

仅需补充验证或修改测试者负责的文件时，Rework 可增加 `ReuseImplementationFrom`，值为当前修订已接受的 executor 调用 ID，或当前修订已经沿用的实现调用 ID。命令确认方案修订一致、实现者负责文件的内容和存在状态相同、原始结果及备份完整，保存实现来源后直接进入 validating。出现普通调用失败后，先完成 Handoff 所要求的角色接续、独立测试、新验收与必要审查；若仍有具体的新一轮补测问题，可沿用未变的实现。失败仍待处理、实现已变化、旧调用缺少实现摘要或同时提交 PlanFile 时，采用默认完整返工。RecoverTask 处理的异常保持完整返工。调用前与完成时再次核对沿用记录；新修订清除交接边界，省略沿用字段会清除上轮沿用关系。验收、真实流程验证及必要结果审查均重新取得本轮证据。

原始任务备份用于回溯最初状态；返工检查其副本完整性和文件覆盖。每次写入调用另捕获当前文件基线并核验，然后启动执行实例。原始备份持续保留。

RecoverLock 核验原锁 owner 和已记录调用进程的退出情况后释放遗留锁，任务的异常仍由 RecoverTask 核验。

`locks/recovery.lock` 是常驻互斥入口；`Status.Lock.recovery.active` 表示当前占用。恢复和普通锁获取共用操作系统句柄互斥，进程退出后句柄释放。RecoverLock 归档后中断可用原 LockToken 重试；返回 recovery_reconfirmed 并补齐审计。锁已释放且无归档时返回 lock_already_free。接入回滚保留互斥基础设施。

RecoverTask 使用当前任务版本、调用及违规 ID、项目内 `collaboration-artifacts/<TaskId>/` 的处理报告路径及 SHA256。ProcessVerification 写明进程树清理检查与结果，FileVerification 写明文件恢复与验证结果。命令检查已记录根进程和子进程不在运行、越界路径恢复为原摘要或原先不存在状态、冻结测试及备份完整性。进程身份或历史修复路径缺失时，先恢复相关记录与现场再核验。

恢复记录关联原始调用和处理报告。原始失败、违规及清理记录保留原值；有效恢复记录解决对应阻断。证据变化后重新核验。成功后任务进入 blocked，使用 Rework 开始新修订，重新执行实现、独立测试及重要任务审查。

恢复记录保存后若状态写入中断，可使用同一请求完成收尾。命令核对原任务字节、修订、摘要、调用集合和报告，重新验证现场并复用恢复记录。已经完成的恢复保持原结果，后续通过 Rework 推进。

调用启动前完成扫描检查并保存带 SHA256 的 baseline.json，随后登记调用；预扫描出错时修正条件后重试。启动后扫描中断保留 pending 检查状态，RecoverTask 读取基线和原扫描配置，重新比较完整项目范围，必要时重做控制比较。维护任务的具名授权沿用本次 WritePaths。恢复报告使用 worker inbox 下的新文件；恢复记录同时绑定调用、基线与报告。监督进程保存的最终 invocation.json 用于记录异常与真实进程身份。

实现变化后逐项更新当前验收状态；需要真实流程时重新取得当前版本证据。RecordAcceptance 将提交文件复制到任务的 `evidence/artifacts/`，返回记录的 `path`、`absolutePath` 指向保存副本，`sourcePath`、`sourceAbsolutePath` 记录来源。完成门禁核验保存副本的摘要。采用此格式的测试报告可按已声明范围重新生成，协调者检查当前结果后重新登记，每次登记得到独立副本。旧修订或当前 Handoff 前的调用结果、已保存证据副本用于回顾；当前验收采用后续验证的产物。

旧版记录的 path、absolutePath 直接指向源报告时，核对其摘要并在原路径保留原件。新报告输出到已授权的新文件或任务 worker inbox（默认 `collaboration-artifacts/<TaskId>/report-r2.txt`），完成当前验证后使用新路径 RecordAcceptance。另存备份用于恢复，原记录仍核验原路径；在旧路径重新生成同名文件仍会被识别为历史证据。任务具名范围固定，需新增测试写入路径时按范围规则安排，协调者可在任务 inbox 保存当前输出。

在 Windows 上运行时，脚本使用挂起启动、Job Object 和进程核算。在 macOS 上运行时，脚本使用启动前握手、专用进程组、精确创建身份、超时与 supervisor 生命周期检查。当前 macOS 实现观察到 fork 事件、脱离进程组或清理无法核实时记录 uncertain，任务进入待处理状态；多进程 CLI 的自动清理验收仍是待完成项。

## 扫描配置

项目库存跳过 `.collaboration/`；独立控制快照检查其中的历史调用、备份、证据和库存，并排除当前调用正在生成的输出流。项目库存保持项目文件信息，历史快照单独保存。

控制目录逐层检查文件和目录，快照使用项目相对路径及区分大小写的键。基线本身另以摘要绑定。派生目录排除同时核对具名任务文件、冻结测试及自定义保护路径的重叠。

`protocol.inventory.exclude` 接受以 `/**` 结尾的派生目录，末级目录名为 node_modules、dist、build、coverage、.cache、.next、.pytest_cache 或 __pycache__，可带项目子目录前缀。默认空列表。示例：`["node_modules/**","coverage/**"]`。任务范围、冻结测试、协作控制路径保持检查；配置与这些路径重叠时先调整配置。排除项适用于可再生依赖、缓存和生成物，相关目录变更由项目构建与测试核验。

## 备份与维护

备份保存原始字节、摘要和平台元数据。Windows 保存文件属性、时间与 SDDL；macOS 保存 mode、uid/gid、ACL、xattrs、flags 和时间，写入前核验备份副本恢复结果。

首次工具登记、隔离验证配置及验证后的 ready 登记属于协调者的接入步骤，保存配置备份与验证依据。已有可用工具后，维护协作控制文件使用 important 任务、Maintenance=true 与具名维护路径。任务等级和当前证据由命令核验，详细规则见项目 [COLLABORATION.md](../../COLLABORATION.md)。

## 配置诊断

运行命令前会校验 `.agents/collaboration/config/collaboration.json` 的必填字段和类型。错误信息指出文件路径及字段，例如 `protected.maintenancePaths`。按同版本配置模板补齐结构并保留项目已有值，再重试命令。`config_missing` 表示配置文件缺失，`config_invalid` 表示无法读取 JSON 或结构校验失败。
