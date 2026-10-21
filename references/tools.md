# 模型与工具接入

技能按角色能力选择工具，项目自行决定使用哪些模型、模型参数和偏好顺序。工具注册表位于项目 `.agents/collaboration/config/tools.json`。

## 从配置样例开始

复制 [examples/tools.json](../examples/tools.json) 并填写本机配置。默认注册表为空；`tools` 可以包含任意数量、具有唯一自定义 `id` 的条目。`preferenceOrder` 可留空，也可以列出项目偏好的工具 ID。

| 字段 | 含义 |
|---|---|
| `id` / `label` | 自定义标识与显示名称；ID 以小写字母开头，总长 1–64 位，其余字符可用小写字母、数字、下划线和连字符 |
| `kind` | 参数及结果的适配协议 |
| `executable` | 当前平台的执行入口；例如 CLI 二进制或运行适配脚本的 Python |
| `requestedModel` | 项目请求的模型；下文说明各协议的传递方式 |
| `allowedRoles` | 项目允许该工具承担的 executor、tester、reviewer、probe；实际角色能力在接入时验证 |
| `commonArgs` / `roleArgs` | 公共参数及各角色专属参数，均为独立字符串数组 |
| `resolve` | `fixed` 使用指定入口；已有 Codex CLI 适配器还支持目录发现 |
| `env` | 非秘密环境参数；认证使用本机工具已有的认证配置或进程环境 |
| `probeArgs` / `probeContains` | 本地版本或能力检查参数，以及预期输出片段 |
| `enabled` / `readiness` | 是否启用及实际验证进度 |
| `observedModel` | 配置中的模型记录；每次调用的实际模型以该次输出为准 |
| `reasoningEffort` | Codex CLI 协议用于构造推理参数；其他协议通过自身参数或配置设置 |
| `nonGitArgs` | Codex CLI 协议在非 Git 目录运行时追加的参数 |
| `notes` | 项目接入和能力验证说明 |

Windows 的执行入口使用原生可执行文件；脚本型适配器把解释器作为 `executable`，把脚本路径放在 `commonArgs` 的开头。macOS 同样可使用解释器或可执行 CLI 路径。

## 通用 JSON 适配器

`kind: "json"` 为不同模型工具提供统一的调用约定。适配器启动独立工作会话，将任务传给所选工具，并将真实完成结果转换成下列 JSON。适配器本身与模型 CLI 都运行在本次受管调用中。

参数支持整项替换：

| 参数项 | 调用时的值 |
|---|---|
| `{promptFile}` | 本次任务提示文件绝对路径 |
| `{prompt}` | 完整任务提示文本 |
| `{role}` | 本次角色 |
| `{model}` | 配置中的模型名称 |
| `{cwd}` | 项目工作目录 |
| `{resultFile}` | 本次结果文件路径 |

参数数组直接交给进程入口。长任务优先传递 `{promptFile}`，适配器读取 UTF-8 文件。

`{model}` 按原值传递；`requestedModel` 为空时传递空字符串，适配器负责将空值解释为采用底层工具的默认模型。JSON 协议通过 `commonArgs` / `roleArgs` 传递其他模型参数。

成功时退出码为 0，stdout 返回一个 JSON 对象：

```json
{
  "schemaVersion": 1,
  "ok": true,
  "final": "实际结果与证据说明",
  "model": "实际使用的模型",
  "session": {"id": "工具实际会话标识", "fresh": true},
  "readOnly": false
}
```

`final` 包含实际交付内容。审查者把规定的裁决声明放在 `final` 的最后非空行。`session.id` 标识工具实际创建的独立会话，`fresh` 表示会话从本次任务开始。会话标识采用“服务身份＋实际会话 ID”，同一服务的不同工具别名使用相同服务身份；运行时跨工具检查历史复用。

reviewer/probe 对应 `readOnly: true`，适配器为这两个角色配置实际的只读工具能力，并附上完整工具事件：

```json
{
  "toolAuditComplete": true,
  "toolEvents": [
    {"type": "tool_call", "name": "read_file", "access": "read"}
  ]
}
```

适配器将底层工具记录规范化为 `tool_call`，保留工具名称，并按真实能力记录 `access`。只读角色的每项事件采用 `read`；未调用工具时使用空数组。运行时核对事件结构、能力类别和已知写入工具名称。接入验证同时检查适配器的实际工具权限与事件完整性。

`model` 可省略，记录中相应显示 `unknown`。失败时返回非零退出码，或返回 `ok: false` 并在 stderr 说明实际原因。日志和失败输出会关联到本次 invocation。

## 已有 CLI 协议适配器

运行时保留 `claude`、`codex`、`zcode`、`grok` 四个 CLI 协议解析器，`kind` 指明参数和结果格式，`id` 可自行命名。模型与供应商由对应 CLI 的参数或 provider 配置选择。

Claude/Codex 适配器会将 `requestedModel` 传给对应模型参数。ZCode/Grok 的模型通过工具本身的 provider 配置或 `commonArgs` 配置，`requestedModel` 用于记录预期；实际模型仍以输出为准。Grok CLI 的提示入口为 `grok -p`。

Claude/Codex 的 `requestedModel` 为空时省略模型参数，由 CLI 自身配置决定。ZCode 协议另需 `entryScript` 指定入口脚本。使用 Codex 的 `discover-version-dir` 时，在 `resolve` 中填写 `root`、`pattern`、`requireVersionContains` 和 `probeMaxAgeDays`。

各角色的工具权限通过 `roleArgs` 配置。现有 Codex CLI 协议要求 reviewer/probe 的参数包含 `--sandbox read-only`，executor/tester 的参数包含 `--dangerously-bypass-approvals-and-sandbox`；其他协议按实际 CLI 的权限参数配置并验证。只读能力由实际执行工具落实，运行时检查相应输出及文件变化。

所有协议的调用记录均包含独立的 `InstanceId`。JSON 协议另外对实际 `session.id` 执行跨工具历史复用检查。原生 CLI 协议当前由协调者在接入与派发时核对新会话参数及原始日志，其实际会话 ID 的统一提取与自动复用检查仍是待完善项。

CLI 角色参数按当前安装版本填写并验证；新工具可实现通用 JSON 约定。接入实现与角色验证记录放在项目工具配置及证据目录中。

## 就绪检查

`ProbeTool` 是本地兼容性检查命令，执行已配置的版本或帮助参数，保存输出、退出码与清理记录。它与 `Invoke` 的 `probe` 角色分别使用：后者是模型参与的只读任务，需要 `TaskId`、独立 `InstanceId`、提示文件和已就绪工具。

1. 登记执行入口、模型、角色及所需参数，在目标项目保持 `readiness=unverified`。
2. 调用 `ProbeTool` 验证本地入口。固定入口的记录绑定执行文件、参数中脚本文件的摘要及角色配置；相对路径按项目根目录解析。JSON 协议在每次 Invoke 前核对该指纹。Codex 目录发现的探测记录按实际二进制摘要、探测时间和兼容性结果绑定。
3. 在独立验证项目中配置相同工具，将该验证副本设为 `enabled=true`、`readiness=ready`，执行 ProbeTool，再用隔离任务检查非交互输入、工作目录、真实输出、会话新建和各角色能力。
4. 检查超时、异常返回和任务进程清理，保存验证证据。
5. 验证通过后在目标项目登记 `enabled=true`、`readiness=ready`，重新运行 ProbeTool，再安排实际开发任务。

`ready` 由协调者依据验证证据登记；ProbeTool 保存兼容性记录。适配器或角色配置变化后，重新执行对应能力验证。

首次登记工具、配置隔离验证副本及验证后的 ready 登记由协调者完成，属于项目接入步骤。已有可用工具后的配置变更按协作控制维护任务推进，并保留相应备份和验证依据。

内置测试工具位于 `tests/fake_worker.py`，供包内回归检查使用。模型调用的真实质量与工具实际能力在项目接入时验证。

macOS 的多进程 CLI 接入仍有待完成项：当前运行时观察到 fork 事件会记录 `cleanup=uncertain`，任务进入待处理状态。具体进度见 [验证记录](validation.md)。
