# 项目运行环境与工具接入

公共入口运行于 PowerShell 7.4+。根据当前操作系统准备下表中的运行组件，协调、实现、测试与审查采用同一套角色职责和任务流程。

| 平台 | 运行组件 |
|---|---|
| Windows | NTFS 项目目录；原生 Job Object 进程管理 |
| macOS | Python 3.11+；专用进程组、实际进程身份、macOS 元数据辅助脚本 |

macOS 平台代码目前处于待实机验证阶段。观察到 fork 事件的调用会记录清理状态 uncertain，多进程 CLI 的自动清理验收仍需完善。

配置位置：

- `.agents/collaboration/config/collaboration.json`：项目目录、保护范围和库存参数。
- `.agents/collaboration/config/tools.json`：工具入口、模型、角色能力及项目偏好。

工具表初始为空。按项目实际情况登记 CLI 或通用 JSON 适配器，先检查本地入口，再在独立验证项目中启用测试配置验证实际角色行为。通过后将本项目条目登记为 enabled=true、readiness=ready。

首次登记、隔离验证配置及验证后的 ready 登记由协调者作为接入步骤完成，保存配置备份与验证依据。已有可用工具后的配置变更按下述维护任务推进。

运行 `Status` 查看任务及状态，运行 `Doctor` 查看配置和入口解析，运行 `ProbeTool` 执行所选工具的本地能力检查。完整参数与结果约定见 [命令说明](.agents/collaboration/README.md)。

接入日志和备份记录在初始化时选择的目录。维护现有项目配置时，使用当前用户授权和相应维护任务，保留修改前原件及验证结果。
