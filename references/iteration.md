# 返工与角色上下文

Rework 与 PrepareContext 服务于同一套协作流程：协调者明确问题，执行者修复，测试者独立验证，重要任务按方案与结果分别审查。原任务的修订、调用与证据持续关联。

普通调用失败通过 Handoff 在当前修订内续作。续作完成且验收、清理、必要审查满足后直接 Complete。尚未 Complete 时，Rework 用于有具体修复目标的新一轮工作，会递增修订并重新取得该轮验证；已 Complete 后出现新问题时创建关联任务。

开始下一轮前，协调者核对同一问题的进展记录：连续两轮无实质进展时停止相关自动派发，说明阻断原因与继续所需条件，按用户明确的继续指示恢复。Rework 递增修订时延续问题的轮次记录。非阻断建议记录裁决或待办，不触发返工。具体判断见 [修复阈值与停止条件](handoff.md#修复阈值与停止条件)。

## 同一任务内返工

任务从 `revision=1` 开始。测试或审查发现需要修复的问题时，先读取 Status 的 Revision、DiffDigest、状态与清理记录，再执行 Rework：

```json
{
  "TaskId": "order-filter",
  "ExpectedRevision": 1,
  "ExpectedDigest": "填写当前 Status 的 DiffDigest",
  "Reason": "修复空筛选条件下返回错误的问题，保留现有接口与文件范围"
}
```

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Rework -RequestFile rework.json
```

Rework 保存上一轮任务快照，递增 revision，重置验收状态和真实流程验证记录。原始备份、历史调用与审查原件持续保留。返工核验原始备份的副本完整性与文件覆盖，每次写入调用另外捕获并核验当前文件基线。任务目标、等级与具名文件范围保持原值；这些内容改变时创建关联任务。

原方案有效时，新修订默认进入 implementing；完成新一轮实现后，推进到 validating，由独立测试者验证。重要任务随后取得新修订的结果审查，再登记当前验收结果并 Complete。仅需补充验证或修正测试者负责的文件时，可按下节引用有效实现，直接进入 validating。每个新修订重新取得独立测试、验收及任务等级要求的结果审查。

### 沿用未变化的实现

当本轮工作是补充验证或修改测试者负责的文件时，在 Rework 请求中增加 `ReuseImplementationFrom`，填写当前修订中已接受的 executor 调用 ID，或当前修订已经沿用的实现调用 ID。Reason 写明待处理问题和本轮验证目标。

```json
{
  "TaskId": "order-filter",
  "ExpectedRevision": 1,
  "ExpectedDigest": "填写当前摘要",
  "Reason": "实现保持原样，补充测试者负责的空输入测试并验证现有验收项",
  "ReuseImplementationFrom": "填写已接受的实现调用 ID"
}
```

运行时核对调用原件、结果、方案修订、原始备份，以及全部实现者负责文件的当前内容和存在状态。新修订保存实现来源并直接进入 validating；测试文件仍遵循创建任务时的 TesterWritePath。调用前和完成时继续核对沿用证据，重要任务重新完成当前修订的结果审查。验收项及真实流程验证重新登记。

当前修订出现过普通调用失败时，先通过 Handoff 记录交接边界，完成待处理角色的接续，并取得交接后的独立测试、验收、所需真实流程验证和重要任务结果审查。连续交接中有效的成功接续结果继续使用。上述条件满足即可完成当前任务；若在 Complete 前发现具体的补测问题，下一次仅补测的 Rework 可以沿用未变实现，原始失败记录继续保存。具体续作顺序见 [任务交接](handoff.md#修复与衔接)。

实现发生变化、需要修改方案、失败仍待处理，或旧记录缺少实现摘要时，使用默认 Rework 完成实现和验证。RecoverTask 处理的范围、控制文件或清理异常仍采用完整返工。需要重新实施时省略 ReuseImplementationFrom；新修订清除此前的实现沿用和交接边界。实现摘要只负责证明内容相同，协调者同时根据问题性质判断是否需要实施修复。

### 修订方案

方案发生变化或方案审查返回 FAIL 时，在 Rework 请求中增加 `PlanFile`，指向项目内的新方案文件。运行时另存方案，更新 `planRevision`，任务回到 planned：

```json
{
  "TaskId": "order-filter",
  "ExpectedRevision": 1,
  "ExpectedDigest": "填写当前摘要",
  "Reason": "补充边界场景与验证方法",
  "PlanFile": "collaboration-artifacts/order-filter/revised-plan.md"
}
```

重要任务重新进行方案审查，登记后 Advance plan_reviewed，已有原始备份时校验其完整性，首次实现前建立备份，然后进入 implementing。未更换方案的实现修复继续沿用有效的 planRevision；执行、测试和结果审查对应新的 revision。

Rework 用于 planned、plan_reviewed、implementing、validating、result_reviewed、blocked 或 handoff_required 中的修复。它检查既有调用清理、冻结测试、项目违规和阻断项；review_fail 随新一轮审查处理，其他阻断项先独立解决。已完成与已取消的任务保留其终态。

## 准备角色上下文

协调者编写简短的本轮任务说明，将相关材料列入 References，将已完成调用列入 PriorInvocationIds：

```json
{
  "TaskId": "order-filter",
  "Role": "tester",
  "ExpectedRevision": 2,
  "ExpectedDigest": "填写当前摘要",
  "PromptFile": "collaboration-artifacts/order-filter/test-brief.md",
  "References": ["src/filter.ts", "tests/filter.test.ts"],
  "PriorInvocationIds": ["填写实际实现调用 ID"],
  "Delta": "This revision fixes empty-filter handling. Verify empty input, existing filters and regression cases."
}
```

运行 `PrepareContext -RequestFile context.json` 后取得 ContextId。生成的交接包包含任务与修订、角色重点、验收要求、本轮简述、变化说明、项目规则及相关文件的路径与摘要，以及前序结果入口。

源码和稳定背景通过引用读取，避免在派发正文中重复复制。协调者按角色选择材料：执行者关注需求与写入范围，测试者关注验收和边界，审查者关注当前方案或结果。

Invoke 的请求使用 ContextId：

```json
{
  "TaskId": "order-filter",
  "Tool": "my-worker",
  "Role": "tester",
  "InstanceId": "tester-r2-01",
  "ContextId": "填写 PrepareContext 返回值",
  "ExpectedRevision": 2,
  "ExpectedDigest": "填写当前摘要",
  "ExpectedPlanSha256": "重要任务填写当前方案摘要"
}
```

ContextId 与直接 PromptFile 是同一 Invoke 的两种材料输入方式；每次选择一个。ContextId 自动核对修订、角色、当前摘要、交接包原件和引用文件；直接 PromptFile 适合已准备好完整材料的调用，ExpectedRevision 可额外核对修订。所有调用仍采用独立 InstanceId、相同的任务阶段及验收规则。
