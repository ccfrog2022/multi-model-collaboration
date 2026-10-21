# 项目内工作流程

协调者先完整读取项目 `AGENTS.md` 引用的规则与命令说明，再执行 `Status` 和 `Doctor`，确认任务、工具、锁、清理和当前版本状态。

项目的公开入口为：

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 <Command> `
    -Root <project-root> -RequestFile <request.json> -Actor coordinator
```

模块入口为 `Invoke-CollabCommand`。参数和模板见项目 `.agents/collaboration/README.md` 与 `templates/`。

下文的 `Advance implementing`、`Invoke executor` 等写法表示操作顺序；实际调用分别在请求 JSON 中填写 `To: "implementing"`、`Role: "executor"`，通过 `-RequestFile` 传入。

## 任务与角色

主会话承担 coordinator，组织方案、派发、证据阅读与验收。executor 完成实现，tester 独立验证，reviewer 只读审查。每次调用采用新的 `InstanceId`，按已确认的任务范围推进。

创建任务时，`TesterWritePath` 指定 AllowedPath 中由测试者编写的测试与测试产物。执行者维护其余文件；冻结测试保持原件。

## 普通任务

1. `NewTask`：登记真实目标、授权、等级理由、验收项和具名 `AllowedPath`。
2. `Backup`：捕获受影响文件的原件与元数据。
3. `Advance implementing`：进入实现阶段。
4. `Invoke executor`：提供当前 `ExpectedDigest` 和本次 `WritePaths`。
5. `Advance validating`：进入验证阶段。
6. `Invoke tester`：使用独立实例；需要写入测试时列出具体 `WritePaths`，仅执行检查时可为空。
7. `RecordAcceptance`：协调者核验原始结果，逐项登记验收证据。
8. `Complete`：签署当前版本的交付结论。

## 重要任务的审查环节

创建任务时提交 `PlanFile`。在实现前调用独立 reviewer 审查方案，`RecordReview` 后推进到 `plan_reviewed`，再进行备份、实现与独立测试。

测试完成后再次调用独立 reviewer 审查当前成果，登记审查与裁决，推进到 `result_reviewed`，最后完成验收。

方案以 SHA256 绑定，结果以任务 `allowedPaths` 中具名文件的实时摘要绑定。项目文件库存用于检查调用前后的写入范围，协作控制快照检查历史证据与控制记录；派生目录按项目扫描配置处理。重要任务的写入调用同时提供 `ExpectedPlanSha256` 和 `ExpectedDigest`；reviewer 提供 `ExpectedSubjectSha256`。

审查结果最后非空行采用以下一种声明：

```text
COLLAB_VERDICT: PASS
COLLAB_VERDICT: PASS WITH NITS
COLLAB_VERDICT: FAIL
```

Findings 中每项提供非空且在本次审查内唯一的 ID；后续交接沿用同一问题的 ID。协调者记录处理结论与复验依据，具体约定见 [任务交接](handoff.md)。

`PASS WITH NITS` 对应具体 Findings 及协调者逐项的非阻断 Adjudication。记录 `FAIL` 后，任务进入 `blocked`；协调者按 [返工说明](iteration.md) 执行 `Rework` 开始新修订，修复后重新审查。方案审查失败时提供修订后的 `PlanFile`。

## 工具与模型

工具从项目注册表选择，模型名称和调用偏好由项目配置。`ProbeTool` 检查所选适配器的本地能力入口，实际工作任务使用验证就绪的配置。通用 JSON 适配器返回真实会话身份；运行时检查此前记录中的会话复用。

## 返工与续作

协调者先按 [修复阈值与停止条件](handoff.md#修复阈值与停止条件) 核对问题记录。同一问题连续两轮无实质进展时，停止相关自动派发，报告阻断原因、尝试证据和继续所需条件，按用户明确的继续指示恢复。非阻断建议记录裁决或待办，不触发返工。

按 [交接说明](handoff.md) 提供变化、缺陷证据和当前版本。任务尚未 Complete 且范围与等级保持一致时，通过 Rework 进入同一任务的新修订；已完成任务的新问题，或目标、范围、等级变化时建立关联任务。

每轮重新取得独立测试及验收记录；重要任务还需当前修订的结果审查。默认重新执行实现；仅需验证或修正测试文件时，可按返工说明用 ReuseImplementationFrom 沿用未变化的有效实现。方案沿用时保留原方案审查；重要任务提供新 PlanFile 时重新进行方案审查。PrepareContext 可将当前修订材料整理为角色交接包，Invoke 使用对应 ContextId。

失败调用保留 invocation、启动前 baseline 和日志；完成扫描时另保存 before/after 与 diff。普通调用失败、文件与清理检查完整时，通过 `Handoff` 衔接；命令保存交接边界并重置验收，待处理失败由对应角色接续。连续交接保留原件、方案及对应摘要仍有效的成功接续结果。每次交接后取得新的独立测试、验收与必要审查，满足条件后直接 Complete 当前修订。有具体的新一轮修复问题时再 Rework，其中仅补测且实现未变的返工可沿用实现。遗留锁通过 `RecoverLock` 检查和恢复。`failed_closed`、清理未知与未决违规在现场处理后，通过 `RecoverTask` 核验恢复，再用完整 Rework 开始新修订，字段见 [异常恢复说明](recovery.md)。

## 完成条件

验收包含独立实现/测试记录、当前摘要对应的测试、有效证据、已验证的清理状态，以及任务等级要求的审查。要求真实用户工作流的任务还记录对应验证结果。协调者阅读原始产物后执行 `Complete`。

测试、结果审查与验收证据同时关联当前修订和文件摘要。沿用的实现另外绑定来源调用原件及实现文件摘要。

RecordAcceptance 将当前测试产物保存为独立验收副本，并记录来源路径。完成时核验副本摘要；固定路径报告的后续更新与历史验收分别保存。Handoff 后，完成条件同时核对交接后的角色验证和新验收证据。

旧版记录直接引用源报告时，原路径保留原件，新报告使用已授权的新路径或任务 inbox，按 [旧版证据步骤](handoff.md#旧版证据继续使用) 登记。
