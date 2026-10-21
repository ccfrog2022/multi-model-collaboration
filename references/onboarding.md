# 项目接入与回滚

接入将随包规则、配置、模板和运行脚本写入目标项目。Windows 和 macOS 使用同一个初始化器及 Plan → Apply → 验证流程。

## 准备

- PowerShell 7.4+；在 macOS 上另准备 Python 3.11+，确保 `python3` 可用。
- 选择实际项目根目录。在 Windows 上项目与备份目录均使用本地 NTFS；在 macOS 上使用可读写的本地目录。
- 项目路径使用实际目录路径，文件采用普通单链接文件，路径大小写保持一致。
- 准备存放接入方案和备份的专属路径。
- 可从 [工具配置示例](../examples/tools.json) 复制工具表，填写当前平台的入口；模型和工具接入见 [工具约定](tools.md)。

下列示例中的变量均填写为实际绝对路径；Windows 和 macOS 使用相同 PowerShell 命令：

```powershell
$initializer = '/absolute/path/to/multi-model-collaboration/scripts/Initialize-Project.ps1'
$projectRoot = '/absolute/path/to/project'
$planFile = '/absolute/path/to/evidence/onboarding-plan.json'
$backupDirectory = '/absolute/path/to/evidence/onboarding-backup'
```

Windows 可使用 `C:/work/project` 这样的路径。macOS 可用 `pwd -P` 确认物理目录路径。

## 生成方案

```powershell
pwsh -NoProfile -File $initializer -Root $projectRoot |
    Set-Content -LiteralPath $planFile -Encoding utf8NoBOM
```

默认操作是 `Plan`，输出文件清单、目标现状、输出摘要、平台元数据策略和方案绑定。协调者核对新增文件、现有 `AGENTS.md` 的追加区段、备份位置、预期效果与回滚步骤。

需要预先填入工具时，在生成和应用方案的两次调用中传入相同的 `-ToolsFile $toolsFile`。接入时保留入口、模型与角色配置，将 `readiness` 设为 `unverified`、`observedModel` 设为 `unknown`，并清空 `notes`；当前项目的能力验证记录随后填写。

## 应用方案

用户确认具体方案后运行：

```powershell
pwsh -NoProfile -File $initializer -Root $projectRoot -Mode Apply `
    -PlanFile $planFile -BackupDirectory $backupDirectory -Confirm
```

初始化器核对方案绑定，取得项目锁，备份现有原件并验证回滚所需元数据，然后写入文件。备份目录使用新的专属路径。

现有 `AGENTS.md` 的原始内容作为前缀保留；协作区段追加在文件末尾。`journal.json` 记录原件、准备写入的内容、文件摘要和逐项状态。重复应用相同的完整接入返回 `no_op`。

## 平台文件元数据

| 平台 | 保存和恢复的信息 |
|---|---|
| Windows | 原始字节、owner/group/DACL、创建/修改/访问时间和文件属性；使用常规 NTFS 文件 |
| macOS | 原始字节、mode、uid/gid、ACL、扩展属性、文件 flags、创建/修改/访问时间 |

每个已有文件先在备份副本上完成元数据恢复与核对，再写入项目目标。macOS 的访问时间可能随读取变化，方案漂移检查比较稳定元数据，备份仍记录并恢复捕获时的访问时间。硬链接、符号链接、immutable/append-only 等特殊文件按命令结果先完成适当准备。

## 验证接入和工具

从项目根目录运行：

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Status
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Doctor
```

核对文件、配置与工具入口后，对项目选定工具执行 `ProbeTool`。在独立验证项目中启用测试配置，验证实际非交互调用、角色能力、输出格式、超时和进程清理；通过后再将目标项目条目登记为 `enabled=true`、`readiness=ready`。具体顺序见 [工具接入约定](tools.md#就绪检查)。工具表位于 `.agents/collaboration/config/tools.json`。

从空工具表开始的首次登记、隔离验证配置和 ready 登记属于协调者的接入步骤，保留配置备份与验证记录。已有可用工具后的配置调整使用项目维护任务。

## 根据记录回滚

核对目标文件和原件备份后运行：

```powershell
pwsh -NoProfile -File $initializer -Root $projectRoot -Mode Rollback `
    -BackupDirectory $backupDirectory -Confirm
```

回滚先检查整份日志与目标状态，再逐项恢复原件或移除接入时新增的文件。备份、日志和空目录保留供复查。执行回滚时使用完成此次接入的同一份技能包。

## 输出

命令输出 JSON，`Ok` 表示结果，`Code` 表示具体状态；成功退出码为 0。常用状态为 `planned`、`applied`、`no_op`、`rolled_back`。应用与回滚结果包含日志路径及写入数量。

## 接入诊断

| 结果 | 如何处理 |
|---|---|
| `package_incomplete` | 查看 `MissingPaths`，从同一版本的完整仓库或 ZIP 补齐 `assets/project/` 下列出的文件，再重新生成方案。保留 `.agents` 目录。 |
| 配置缺字段或类型错误 | 错误信息包含配置文件路径和字段，例如 `protected.maintenancePaths`；以同版本 `collaboration.json` 为结构参考，保留项目已有值，补齐或修正该字段。 |
| 配置 JSON 无法读取 | 按错误信息中的文件路径检查文件访问权限和 JSON 语法。 |
| Windows 文件读取失败 | 信息包含具体路径、Win32 错误码和系统原因，按实际路径或权限问题处理。 |

配置结构包括 `schemaVersion=1`、`paths`、`protocol` 和 `protected`。`protocol.serial` 为布尔值，库存上限为正整数；路径列表为字符串数组，可使用空数组。初始化方案与项目运行命令共用字段校验规则，错误配置在任务状态写入之前报告。

发布检查命令为 `pwsh -NoProfile -File tests/Test-Distribution.ps1`。该检查在新建的隔离目录中验证缺文件与配置异常，并完成正常接入、Doctor 和回滚。
