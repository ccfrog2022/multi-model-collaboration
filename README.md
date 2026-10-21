# Multi-Model Collaboration

**简体中文** | [English](README.en.md)

**面向软件开发、以独立验证提升交付质量的多模型协作 Skill。**

主会话协调需求与任务，执行者实现代码，测试者独立验证，审查者检查方案与成果。每个环节围绕共同的验收条件协作，通过任务身份、当前版本和原始证据交接工作。

## 为什么使用它

- **清晰分工**：协调、实现、测试和审查各有职责与交付。
- **独立验证**：普通任务完成独立测试；重要任务增加方案审查和结果审查。
- **可追溯交接**：每次调用关联任务、实例、模型、产物版本与证据。
- **减少重复上下文**：按角色准备必要材料，稳定背景通过文件引用，返工补充变化。
- **连贯返工**：在同一任务内记录修订，保留历史证据，重新验证修复结果。
- **异常恢复**：核验处理证据与现场后追加恢复记录，再进入新一轮实现和独立验证。
- **角色写入边界**：任务创建时明确测试者可写文件，执行者与测试者分别维护自己的产物。
- **自由配置模型**：项目自行选择模型和执行工具，配置角色能力与调用偏好。
- **统一跨平台流程**：在 Windows 或 macOS 上运行时，采用相同的角色职责和任务、测试、审查、验收命令。

从零了解具体工作方式，请阅读 [SKILL.md](SKILL.md)。

[查看架构与运行逻辑图](assets/diagrams/architecture-workflow.png)。

## 完整目录

```text
multi-model-collaboration/
├── SKILL.md
├── SKILL.en.md
├── README.md
├── README.en.md
├── agents/openai.yaml
├── scripts/Initialize-Project.ps1
├── references/
│   ├── onboarding.md
│   ├── workflow.md
│   ├── handoff.md
│   ├── recovery.md
│   ├── iteration.md
│   ├── tools.md
│   └── validation.md
├── examples/tools.json
├── tests/
│   ├── Test-Package.ps1
│   ├── Test-CoordinationCases.ps1
│   ├── Test-ReworkReuseCases.ps1
│   ├── Test-ContinuationEvidenceCases.ps1
│   ├── Test-RecoveryCases.ps1
│   ├── Test-ExceptionalCases.ps1
│   ├── Test-LockRecoveryCases.ps1
│   ├── Test-PathIdentityCases.ps1
│   ├── fake_worker.py
│   └── test_platform_contracts.py
└── assets/
    ├── diagrams/
    │   ├── architecture-workflow.png
    │   └── architecture-workflow.en.png
    └── project/
        ├── AGENTS.md
        ├── COLLABORATION.md
        ├── COLLABORATION-SETUP.md
        ├── .agents/collaboration/
        │   ├── README.md
        │   ├── config/
        │   └── templates/
        └── scripts/collaboration/
            ├── Collab.ps1
            ├── Collab.psm1
            ├── lib/
            └── native/
                ├── Collab.Native.cs
                └── platform_macos.py
```

整个目录构成一个 skill。项目初始化器从同目录的 `assets/project/` 复制命令、规则与模板，所有配套源文件随目录提供。上传和复制时保留隐藏的 `.agents` 目录。

## 环境准备

| 环境 | 依赖与平台实现 |
|---|---|
| Windows | PowerShell 7.4+、NTFS；使用 Windows Job Object 管理受管进程 |
| macOS | PowerShell 7.4+、Python 3.11+；使用专用进程组与进程身份检查，保存 macOS 文件元数据 |
| 模型工具 | 用户准备对应 CLI 或 JSON 适配器，并在项目中登记入口和模型参数 |
| 本地测试 | PowerShell 7.4+、Python 3.11+；测试工具在本地生成确定性结果 |

用户按当前操作系统准备对应依赖，运行脚本选择相应的平台实现。平台实测进度与测试范围记录在 [验证记录](references/validation.md)。

当前 Windows 已开展隔离回归，macOS 已加入平台实现，实机验证与多进程 CLI 清理验收仍在推进。

## 安装与开始使用

将本目录复制到编程助手的技能目录，文件夹命名为 `multi-model-collaboration`。例如 Codex 的默认技能目录是 `~/.codex/skills/`。保持目录内部结构完整。

在目标项目会话中输入：

```text
使用 $multi-model-collaboration，为当前项目准备协作接入方案。
```

协调者生成文件级方案，展示接入内容、验证与回滚安排，确认后写入项目。接入细节见 [项目接入说明](references/onboarding.md)。

项目接入后可以提出具体开发目标：

```text
使用 $multi-model-collaboration，实现订单筛选功能。
先明确验收条件，安排实现与独立测试，最后汇总实际验证结果。
```

重要变更示例：

```text
使用 $multi-model-collaboration，重构权限校验流程。
先安排独立方案审查，实现后进行独立测试与结果审查。
```

## 模型和工具配置

默认工具表为空。将 [examples/tools.json](examples/tools.json) 作为起点，填写项目实际使用的工具：

- `id`：自定义工具名称。
- `executable`：当前平台的可执行文件绝对路径。
- `requestedModel`：项目请求的模型；具体传递方式与空值处理见工具接入约定。
- `allowedRoles`：该工具可以承担的角色。
- `commonArgs` / `roleArgs`：公共调用参数与角色参数。
- `preferenceOrder`：项目自行选择的工具顺序。

通用 JSON 适配器统一返回最终结果、实际会话身份及可用的模型信息。具体协议、原生 CLI 适配器和就绪检查见 [工具接入约定](references/tools.md)。

## 质量与协作交接

所有实施任务由独立测试者验证当前版本。重要任务的方案和成果分别接受独立审查。协调者根据原始产物和证据逐项验收。

上下文按角色准备，任务摘要引用详细证据；返工优先传递变化内容和当前问题。模型选择与推理参数由项目配置承担成本取舍，独立测试和必要审查保持完整。

`Rework` 在原任务内开始下一轮修复。仅需补充验证或修改测试文件时，可引用已完成且内容未变的实现，直接进入独立测试；新修订继续取得验收与必要审查证据。`PrepareContext` 生成带有修订与文件摘要的角色交接包。操作示例见 [返工与角色上下文](references/iteration.md)。

验收登记保存提交文件的独立副本及来源信息。固定路径的测试报告可以按任务范围重新生成，历史验收继续对应已保存的内容。

派发写明本次完整交付目标、验收依据和阻断条件，工作实例完成相应工作及检查后回传。问题用简短 ID 关联处理结果和复验依据；回传先说明结论与关键证据，再按实际问题展开细节。相关改动、失败或证据冲突发生时继续检查。

协调者按同一问题记录修复尝试与验证结果。连续两轮无实质进展时，停止该问题相关的自动派发，说明阻断原因、两轮证据及继续所需条件，按用户明确的继续指示恢复派发。Handoff、Rework 或更换模型延续同一问题的记录。非阻断建议记录裁决或待办，不触发返工；验收满足且阻断问题关闭后交付。判断方法见 [修复阈值与停止条件](references/handoff.md#修复阈值与停止条件)。

## 恢复与扫描配置

出现范围违规或清理待核验时，协调者处理现场并准备具体证据，使用 `RecoverTask` 登记核验结果，再由 `Rework` 开始新修订。失败调用、违规和清理原件持续保存，恢复记录关联其摘要及证据。

文件与清理检查完整的普通调用失败通过 `Handoff` 在当前修订内接续。连续交接会保留原件、方案及对应文件摘要仍有效的成功接续结果，待处理失败由相应角色继续完成；每次交接后取得独立测试、新验收及必要结果审查。条件满足后直接 `Complete`。尚未 Complete 时，有具体的新一轮修复问题可 `Rework`，其中仅补测且实现未变的返工可以沿用实现；已完成任务的新问题创建关联任务。

新版验收登记保存独立证据副本。旧版记录仍直接引用源报告时，在原路径保留旧原件，新报告采用已授权的新路径或任务 inbox，再登记当前证据。步骤见 [任务交接与旧版证据说明](references/handoff.md)。

启动前扫描失败时，修正配置或文件条件后重新调用。启动后扫描中断时，恢复核验读取已绑定的启动前基线并重新检查完整差异。恢复后的任务继续沿统一流程实现、独立测试、交接与验收。

`RecoverLock` 用于遗留项目锁；恢复操作通过操作系统句柄互斥，进程退出后句柄自动释放。`Status` 同时显示项目锁与恢复互斥状态。文件角色范围在创建及调用时核对身份，macOS 按实际文件和所在文件系统的大小写规则处理别名。

文件检查采用项目库存和协作控制快照分工。历史记录保持完整性核验，项目库存集中保存源码及其他项目文件。可配置派生目录排除以减少依赖和生成物扫描；任务文件、冻结测试与协作控制文件保持检查。参数示例见 [恢复与扫描说明](references/recovery.md)。

## 本地验证

在 skill 根目录运行：

```powershell
pwsh -NoProfile -File tests/Test-Package.ps1 -Python /absolute/path/to/python
```

`-Python` 填写本机 Python 路径；省略时 Windows 查找 `python`，macOS 查找 `python3`。测试在新建的独立目录验证接入、回滚、普通与重要任务、版本校验、独立性、扫描中断恢复、恢复后交接、锁并发和进程清理，并输出记录路径。平台实测与模拟测试分别记在 [验证记录](references/validation.md)。

## 进一步阅读

- [完整技能说明](SKILL.md)
- [接入与回滚](references/onboarding.md)
- [开发、测试与验收](references/workflow.md)
- [任务交接与上下文](references/handoff.md)
- [返工与角色上下文](references/iteration.md)
- [工具接入约定](references/tools.md)
- [异常恢复、扫描与角色边界](references/recovery.md)
- [验证记录](references/validation.md)
