# 异常恢复、扫描与角色边界

异常处理后的继续派发遵循 [修复阈值与停止条件](handoff.md#修复阈值与停止条件)：同一问题连续两轮无实质进展时，完成当前清理与证据保存，停止相关自动派发，说明阻断原因和继续所需条件，按用户明确的继续指示恢复。恢复核验、Handoff 和 Rework 延续同一问题记录。

这些能力沿用现有协作流程。协调者负责处理异常与派发，执行者维护实现，测试者独立验证；重要任务继续进行方案和结果审查。

## 异常恢复顺序

1. 用 Status 查看任务、当前 Revision、DiffDigest、违规 ID、调用记录与清理标记。
2. 如果遗留项目锁阻止操作，先检查原 owner 与已记录调用进程，使用 RecoverLock 恢复锁。任务异常状态继续保留。
3. 阅读失败调用的日志、`baseline.json`、文件差异、repairPaths 和进程身份。核验任务自建进程及其子进程已退出，把越界文件恢复至记录的摘要或原先不存在状态，检查冻结测试与原件备份。
4. 在 `collaboration-artifacts/<TaskId>/` 使用新文件保存处理报告，说明检查对象、命令、实际结果和处理过程。取得报告 SHA256，准备 RecoverTask 请求。
5. RecoverTask 通过检查后追加恢复记录，任务进入 blocked，下一步执行 Rework。新修订完成实现、独立测试及任务等级要求的审查与验收。

RecoverTask 负责核验与登记；现场文件恢复和进程处理由协调者按原始证据完成。缺失进程身份、原始备份或历史修复路径时，先恢复相关记录与现场，再进行核验。进程快照检查覆盖已记录的根进程与子进程；ProcessVerification 和处理报告补充完整进程树核验过程。macOS 的多进程追踪仍按 [验证记录](validation.md) 跟进。

### 扫描中断如何接续

启动前先完成扫描配置、库存完整性和控制快照检查，再保存调用记录；该阶段出错时直接修正条件并重试。每次实际调用在启动前保存 `baseline.json`，其中包含项目库存、控制快照和本次扫描配置，调用记录保存其 SHA256。

启动后扫描中断时，`scopeCheck` 或 `controlCheck` 保持 `pending`。RecoverTask 先核对基线摘要，按原扫描配置重新生成完整库存，再比较本轮写入范围之外的内容变化；控制扫描中断时也重做控制差异检查。已恢复内容以字节摘要为准，报告使用基线中尚不存在的新路径。空的 repairPaths 只是已记录路径列表，完整范围仍由基线比较核验。

当前 invocation.json 由监督进程保存最终记录，包含真实进程身份和异常信息；对其改写会形成违规，恢复核验使用监督进程保存的最终记录。恢复证据绑定调用、基线与报告。Handoff 和 Rework 共同采用这些有效恢复记录判断历史清理情况。

### 请求示例

```json
{
  "TaskId": "order-filter",
  "ExpectedRevision": 1,
  "ExpectedDigest": "当前 Status 的 DiffDigest",
  "InvocationIds": ["失败调用 ID"],
  "ViolationIds": ["当前任务的违规 ID"],
  "EvidencePath": "collaboration-artifacts/order-filter/recovery.md",
  "EvidenceSha256": "处理报告 SHA256",
  "Reason": "说明异常原因与已完成的处理",
  "ProcessVerification": "记录进程身份、进程树检查、清理动作与退出结果",
  "FileVerification": "记录越界路径恢复、冻结测试和原始备份检查结果"
}
```

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 RecoverTask -RequestFile recover-task.json
```

InvocationIds 包含当前任务所有待核验清理的调用及违规对应调用；ViolationIds 列出该任务当前未解决的违规，无违规时使用空数组。其他任务的异常分别处理。版本或摘要变化后重新读取 Status。

恢复记录保存在 `.collaboration/recoveries/`，绑定原始调用和处理报告的摘要，同时关联原始违规与清理标记。原件持续保留原值；有效恢复证据改变对应检查结果。报告或调用原件变化后重新进入核验。恢复成功表示现场处理已登记，最终交付继续依据新修订的独立验证。

若恢复记录已保存而任务状态更新中断，同一请求可在任务原件、修订、摘要、调用集合和报告仍匹配时继续收尾；命令重新核验现场并复用原恢复记录。已经完成的恢复保持原结果，后续工作从 Rework 进入新修订。

## 遗留锁与恢复互斥

`Status.Lock` 显示项目锁；其中 `recovery.active` 显示恢复互斥是否占用。`locks/recovery.lock` 是常驻的互斥文件，文件存在表示互斥入口已建立。互斥由打开的操作系统句柄持有，进程退出后自动释放。

RecoverLock 使用原项目锁的 `LockToken`、具体 `Reason` 和 `Confirm=true`，核验原 owner 及调用进程后归档遗留锁。归档后中断可用同一 token 重试，返回 `recovery_reconfirmed` 并补齐审计；锁已经释放且无归档时返回 `lock_already_free`。新的项目锁使用自己的 token。普通操作与恢复操作共用互斥入口，接入回滚保留该基础设施。

## 划分实现与测试文件

NewTask 中的 AllowedPath 是任务全部具名可写文件。TesterWritePath 指定其中由测试者维护的测试文件或测试产物；执行者负责其余文件。例如：

```json
{
  "AllowedPath": ["src/filter.ts", "tests/filter.test.ts", "test-results/filter.json"],
  "TesterWritePath": ["tests/filter.test.ts", "test-results/filter.json"],
  "FrozenTest": ["tests/existing-regression.test.ts"]
}
```

这些字段与任务身份一起在创建时保存。每次 Invoke 的 WritePaths 进一步限定本轮文件，运行前检查所属角色。省略 TesterWritePath 时，测试者读取与执行检查；需要创建测试或保存测试产物时，在建任务时列入对应路径。已有任务的文件职责变化时建立关联任务。

`test-results/filter.json` 是可重新生成的测试产物。协调者检查当前输出后通过 RecordAcceptance 登记，命令将其复制到任务的 `evidence/artifacts/` 并保存来源路径和摘要。后续测试可以按原范围更新报告，每次登记生成独立验收副本；历史验收继续指向之前保存的内容。

旧版记录直接绑定源报告时，在原路径保留原件，将当前报告写到已授权的新路径或任务 inbox 后登记，具体见 [旧版证据继续使用](handoff.md#旧版证据继续使用)。

测试者发现实现问题后，提供复现步骤、具体位置和预期结果，协调者安排执行者返工。测试文件在独立测试完成后参与当前成果摘要和验收记录。

macOS 在角色冲突检查中用设备与 inode 识别已有文件别名，未创建目标使用最近已有父目录及文件系统大小写规则。调用后的范围检查和恢复核验按父目录与文件名判断授权，因此新增硬链接仍须拥有自己的具名授权。查询过程只读取元数据。Windows 对路径使用不区分大小写的范围判断。文件名采用项目实际拼写。

## 减少扫描重复

运行时分别维护：

- **项目库存**：源码、测试与其他项目文件的摘要及差异，跳过 `.collaboration/`。
- **控制快照**：规则、工具配置和 `.collaboration/` 内的调用、备份、证据、恢复记录及历史库存，检查其完整性。当前调用正在生成的输出流由受管进程单独记录。

历史库存保持单独存储，后续项目库存集中记录项目文件。历史控制文件仍逐次核验，因此长期使用仍有随记录数量增长的开销；本次减少的是重复扫描和快照内容增长。

控制文件采用项目相对路径作为键，并保留大小写不同文件的独立摘要。启动前基线本身另以 SHA256 绑定，控制快照中的当前调用记录采用一个相对路径键。

### 派生目录配置

项目 `.agents/collaboration/config/collaboration.json` 中可设置：

```json
{
  "protocol": {
    "inventory": {
      "maxFiles": 50000,
      "maxHashBytes": 1073741824,
      "exclude": ["node_modules/**", "coverage/**"]
    }
  }
}
```

示例展示 inventory 所在层级；编辑时保留配置中的其他字段。exclude 默认空列表。路径以 `/**` 结尾，末级目录名采用 node_modules、dist、build、coverage、.cache、.next、.pytest_cache 或 __pycache__，可添加项目子目录前缀，如 `web/node_modules/**`。

这些目录用于可再生依赖、缓存和构建产物；排除后其中的文件变化由项目构建与测试核验。任务 AllowedPath、冻结测试及受保护协作路径与排除配置保持分离，重叠配置在调用前报告。代码摘要检查与独立验收继续执行。
