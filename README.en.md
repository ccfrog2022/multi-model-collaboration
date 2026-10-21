# Multi-Model Collaboration

[简体中文](README.md) | **English**

**A software development skill that improves delivery quality through clear responsibilities and independent verification.**

Multi-Model Collaboration makes the coding assistant's main conversation the coordinator, with separate model sessions responsible for implementation, testing and review. Everyone works toward the same requirements, file versions and acceptance criteria. The coordinator delivers after inspecting actual code and verification evidence.

The package includes collaboration instructions, a project initializer, runtime scripts, tool configuration templates and local tests. Once installed into a project, it records dispatches, task revisions and acceptance evidence so later work can build on existing results. Models and execution tools are configured per project; the same model can perform different roles through independent sessions.

![Multi-Model Collaboration roles, architecture, workflow, recovery and stopping conditions](assets/diagrams/architecture-workflow.en.png)

[View the full architecture diagram](assets/diagrams/architecture-workflow.en.png)

## What it is useful for

- **Feature development:** establish expected behavior, then implement and verify independently.
- **Bug fixes:** use reproduction steps and failure evidence to guide repairs and check boundary and regression effects.
- **Cross-file refactoring:** coordinate changes through explicit file ownership and acceptance criteria, with plan and result reviews for important tasks.
- **Delivery verification:** inspect the current version, test output and real user workflows to produce a delivery conclusion supported by evidence.

The workflow is especially useful for development that needs independent checks, multiple repair rounds or preserved handoff evidence. It requires configured model tools and adds independent calls, file checks and evidence records. Task scope and risk determine review depth.

## How the four roles work together

An instance is a model work session with its own identity and context. Roles define responsibilities; project configuration selects the model.

| Role | Responsibility | Deliverable |
|---|---|---|
| coordinator | The main conversation understands requirements, plans tasks, selects tools, dispatches work and accepts results | Goals, file scope, acceptance criteria and final conclusions |
| executor | Implements features or repairs within assigned files | Actual code changes, implementation notes and relevant checks |
| tester | Independently examines the implementation, writes or runs tests, and covers boundaries and regressions | Test results, reproduction steps and defect evidence |
| reviewer | Performs read-only review of plans or results for correctness, omissions and risks | Verdict, concrete findings and evidence |

Implementation files and tester-owned files are assigned when the task is created; existing frozen tests retain their originals. The coordinator arranges dispatch and integration, and workers return their assigned deliverables. Managed calls currently run serially within a project, with independent sessions for each role.

## How a request reaches completion

The skill follows one development workflow. Task grade determines which review stages are required.

1. **Establish the goal:** the coordinator reads project rules and relevant source, turns requirements into verifiable acceptance criteria, and sets file scope and task grade.
2. **Prepare the plan:** ordinary tasks proceed to implementation; important tasks first receive an independent plan review.
3. **Back up and implement:** preserve originals, let the executor make changes within scope, and record invocation identity and artifact version.
4. **Test independently:** the tester verifies the current implementation against requirements and returns reproducible results and defect evidence.
5. **Review results:** important tasks receive an independent result review of the current changes and supporting tests.
6. **Accept and deliver:** the coordinator inspects source, diffs and original output, then records acceptance for the current version. Tasks requiring a real user workflow also verify that workflow.

For an order-filtering feature, for example, the coordinator defines filter combinations, empty results and reset behavior. The executor implements the UI and logic, and an independent tester checks those behaviors and relevant regressions. Defects affecting acceptance lead to a specific repair and verification round; satisfied acceptance leads to delivery.

The outcome includes **project changes, independent verification results, required review conclusions, and a delivery explanation with evidence tied to the current version**. These records also support later continuation and inspection.

## Quality, communication and resource use

Quality checks rely on separate responsibilities, verification of the current version and coordinator acceptance. Ordinary tasks include implementation and independent testing; important tasks add plan and result reviews. Review depth follows risk.

Handoffs are tailored to the role: executors receive requirements and implementation scope, testers receive acceptance criteria and boundary cases, and reviewers receive the review subject and evidence. Stable background is referenced by path and digest; rework focuses on changes and current issues. Workers receive a complete deliverable, acceptance criteria and blockers to report, then return conclusions and decisive evidence. Relevant changes, failures or conflicting evidence trigger further checks. These practices aim to reduce tokens spent on repeated copying, summaries and checks without a specific purpose.

When only additional verification or tester-owned file changes are needed, the runtime can validate and reuse an intact, unchanged implementation. The new revision still needs independent testing, acceptance and required result reviews. Projects configure models and reasoning parameters according to capability, quality requirements and resource budgets. Actual runtime and token use depend on the task and tools.

A stable issue ID connects repair attempts to verification results. **After two consecutive rounds without substantive progress, the coordinator stops automatic dispatch related to that issue**, explains both rounds' evidence, the blocker and conditions needed to continue, and resumes on the user's explicit continuation instruction. The coordinator applies this threshold using evidence; unsatisfied acceptance criteria remain unpassed. Non-blocking suggestions receive a disposition or backlog entry. Delivery follows satisfied acceptance and closed blockers.

## Interruptions, continuation and rework

| Situation | Next step |
|---|---|
| An ordinary invocation fails, with complete file and process-cleanup checks | Use `Handoff` to continue the current revision. Consecutive handoffs retain valid successful replacements. Obtain post-handoff independent testing, acceptance and required result review, then directly `Complete` |
| A concrete issue blocks acceptance in the current task | Use `Rework` to start a new revision. Eligible additional verification or tester-owned file repairs may reuse unchanged implementation |
| Scope violations, interrupted scans or uncertain cleanup occur | Handle the affected state and verify it through `RecoverTask`, then perform full `Rework` with implementation and verification |
| A new issue follows completion, or the goal, scope or grade changes | Create a linked task referencing prior results and unresolved issues; retain the attempt history for the same issue |

Acceptance registration saves an independent copy of evidence and its source information, preserving earlier results when reports are updated. For legacy records that directly reference a source report, keep the original at its path and write the new report to an authorized new path or the task inbox. See [Recovery](references/recovery.md) and [Handoffs](references/handoff.md) for stale locks, scan exclusions and recovery evidence.

## Requirements

| Environment | Dependencies and platform implementation |
|---|---|
| Windows | PowerShell 7.4+, NTFS; Windows Job Objects manage owned processes |
| macOS | PowerShell 7.4+, Python 3.11+; dedicated process groups, process-identity checks and macOS file-metadata preservation |
| Model tools | Configure an available CLI or JSON adapter, its entry point and model arguments |
| Local tests | PowerShell 7.4+, Python 3.11+; deterministic test workers run locally |

Prepare the dependencies for the current operating system; scripts select its platform implementation. [Validation](references/validation.md) records actual platform testing and coverage.

Windows has undergone isolated regression testing. macOS has a platform implementation; real-machine validation and cleanup acceptance for multi-process CLIs are still in progress.

## Install and get started

Copy the complete directory into your coding assistant's skills directory and name it `multi-model-collaboration`. For example, Codex's default is `~/.codex/skills/`. Keep the internal structure intact.

In the target project's conversation, enter:

```text
Use $multi-model-collaboration to prepare a collaboration setup plan for this project.
```

The coordinator generates a file-level plan, explains the setup, validation and rollback arrangements, then applies it after confirmation. See [Project onboarding](references/onboarding.md).

Once the project is configured, describe a development goal:

```text
Use $multi-model-collaboration to implement order filtering.
Establish acceptance criteria, arrange implementation and independent testing,
then summarize the actual verification results.
```

For an important change:

```text
Use $multi-model-collaboration to refactor the authorization checks.
Arrange an independent plan review first, then independent testing
and a result review after implementation.
```

## Configure models and tools

The default tool registry is empty. Start with [examples/tools.json](examples/tools.json) and configure tools available to the project:

- `id`: a tool name of your choice.
- `executable`: the absolute executable path for the current platform.
- `requestedModel`: the requested model; the tool contract describes argument mapping and empty values.
- `allowedRoles`: roles this tool may perform.
- `commonArgs` / `roleArgs`: shared and role-specific arguments.
- `preferenceOrder`: the project's preferred tool order.

Generic JSON adapters return a final result, actual session identity and available model information. See the [tool integration contract](references/tools.md) for the protocol, native CLI adapters and readiness checks.

## Package contents and reading guide

The complete directory forms one skill. Preserve its structure during installation and upload, including the hidden `assets/project/.agents/` directory.

| File or directory | Purpose |
|---|---|
| [README.md](README.md) / [README.en.md](README.en.md) | User-facing introduction, requirements and getting started |
| [SKILL.md](SKILL.md) / [SKILL.en.md](SKILL.en.md) | Agent execution instructions: roles, workflow, handoffs, acceptance and stopping conditions |
| [references/](references/) | Detailed command workflows, setup, recovery and evidence rules to read as needed |
| [scripts/Initialize-Project.ps1](scripts/Initialize-Project.ps1) | Plan, apply or roll back setup in a target project |
| [assets/project/](assets/project/) | Bundled project rules, runtime scripts, tool configuration and task templates |
| [assets/diagrams/](assets/diagrams/) | Chinese and English architecture and workflow diagrams |
| [examples/tools.json](examples/tools.json) | Example tool and model configuration |
| [agents/openai.yaml](agents/openai.yaml) | Client display metadata |
| [tests/](tests/) | Local verification scripts and deterministic test workers |

The initializer copies runtime content from `assets/project/`. A configured project includes rules, command documentation, configuration and templates under `.agents/collaboration/`, and runtime scripts under `scripts/collaboration/`. Task execution then creates the corresponding records.

## Local verification

Run from the skill root:

```powershell
pwsh -NoProfile -File tests/Test-Package.ps1 -Python /absolute/path/to/python
```

Set `-Python` to the local interpreter path. When omitted, Windows looks for `python` and macOS for `python3`. Tests use a new isolated directory to verify setup, rollback, ordinary and important tasks, version and independence checks, interrupted-scan recovery, post-recovery handoffs, lock concurrency and process cleanup. They print the record location. [Validation](references/validation.md) distinguishes platform tests from simulated checks.

## Further reading

The detailed references and project command documentation are currently in Simplified Chinese.

- [Agent execution instructions](SKILL.en.md)
- [Onboarding and rollback](references/onboarding.md)
- [Development, testing and acceptance](references/workflow.md)
- [Handoffs and context](references/handoff.md)
- [Rework and role context](references/iteration.md)
- [Tool integration contract](references/tools.md)
- [Recovery, scanning and role boundaries](references/recovery.md)
- [Validation](references/validation.md)
