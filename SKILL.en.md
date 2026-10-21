---
name: multi-model-collaboration
description: A multi-model collaboration skill for software development, organizing quality-first work through coordination, implementation, independent testing and review. Use for feature development, bug fixes, refactoring, delivery verification, and collaboration setup for Windows and macOS projects.
---

# Multi-Model Collaboration

[简体中文](SKILL.md) | **English**

Multi-Model Collaboration is a skill for software development. The main conversation organizes requirements and tasks, independent worker sessions handle implementation, testing and review, and delivery follows inspection of the actual artifacts and verification results.

![Multi-Model Collaboration roles, architecture, workflow, recovery and stopping conditions](assets/diagrams/architecture-workflow.en.png)

[View full-size diagram](assets/diagrams/architecture-workflow.en.png)

Its core principle is to **improve development quality through clear responsibilities, independent verification and traceable handoffs**. Planning, implementation, testing and acceptance share the same objective, file versions and acceptance criteria.

This document explains the skill, its workflow and its entry points. It also guides agents using the skill. Detailed command parameters and setup procedures are provided in the supporting references.

## What it helps with

Ongoing development requires understanding requirements, changing code, checking results and handling rework. Assigning clear responsibilities lets separate sessions examine the implementation, its behavior and whether the delivery meets the requirements.

The skill organizes collaboration around four practices:

- **Clear ownership:** each session knows its responsibility, writable files and expected deliverables.
- **Independent checks:** testing uses a session independent of the implementer; important tasks also receive plan and result reviews.
- **Continuity:** successors receive the current version, existing results and unresolved issues.
- **Evidence-based delivery:** the coordinator inspects source, actual changes, test output and acceptance records before reaching a conclusion.

Typical uses include feature development, defect repair, cross-file refactoring and deliveries that benefit from independent checks.

## How the four roles work together

An instance is a model work session with an explicit task, role and identity. Independent instances can use the same model or different models selected through project configuration.

| Role | Responsibility | Deliverables |
|---|---|---|
| coordinator | The main conversation understands requirements, plans and splits tasks, dispatches work, reads source and evidence, and organizes rework and acceptance | Task scope, acceptance criteria, dispatch materials and delivery conclusions |
| executor | Implements the assigned change within its file scope | Code changes, implementation notes and relevant verification results |
| tester | Independently checks requirements and implementation, writes or runs tests, and covers boundaries and regressions | Test results, reproduction steps and defect evidence |
| reviewer | Reviews the plan or current result with read-only access, checking correctness, omissions and risks | Verdict, concrete findings and supporting evidence |

The executor owns implementation code, the tester owns test code, and the coordinator owns organization and acceptance. At task creation, `AllowedPath` lists all writable files and `TesterWritePath` selects the tests and test artifacts owned by the tester. Other writable files belong to the executor. Existing frozen tests retain their originals. Implementation, testing and review use separate instances. The coordinator arranges model calls and integration; each worker returns its assigned deliverable.

For tool setup, `ProbeTool` performs local version or capability checks. When model-assisted analysis of compatibility is useful, a task can invoke the read-only `probe` role using a ready tool and an independent instance.

File ownership is checked by file identity. On macOS, checks account for existing file identity and the filesystem's case rules for targets that do not yet exist. Windows scope checks use case-insensitive paths.

## How a task reaches completion

### 1. Understand the request and project

The coordinator reads the project's `AGENTS.md` and its referenced collaboration rules, then checks progress, relevant source, user requirements and available tools. Establish the goal, change scope and verifiable acceptance criteria before implementation.

When the user requests analysis or a proposal first, deliver that phase. Once implementation begins, continue within the agreed scope.

### 2. Plan the work and reviews

The coordinator chooses a task grade under project rules and records the reason. An ordinary task goes through implementation, independent testing and coordinator acceptance. An important task adds independent plan review before implementation and result review after testing.

A localized fix with clear impact may be ordinary. Changes to critical behavior, data structures or substantial architecture should be assessed as important under project rules. Review depth follows risk; responsibilities and acceptance principles apply throughout.

### 3. Dispatch and implement

The coordinator creates the task record, prepares backups of originals, and supplies exact file scope, current versions, necessary context and acceptance criteria. The executor completes the assignment and returns actual changes and verification results.

Every managed invocation uses a fresh `InstanceId`. Managed calls within a project run serially, with task records linking each invocation to its artifacts.

### 4. Test independently and review the result

The tester checks the current implementation against requirements and acceptance criteria, runs relevant tests and records reproducible results. Existing frozen tests remain stable acceptance evidence.

Important-task result reviews target the current file version. When an issue affects agreed acceptance or progress, the coordinator uses `Rework` to begin a new revision of the same task. Give the responsible role the location, impact, evidence and expected outcome, then verify the corrected version. Changes to the objective, scope or grade use a linked task.

Use short issue IDs to connect locations, dispositions and verification evidence. Keep the same ID for the same issue. The coordinator records whether it is fixed, still open or disputed with evidence. Deliver once acceptance is satisfied and blocking issues are closed. Record non-blocking suggestions as dispositions or backlog items; they do not trigger rework.

### 5. Accept and deliver

The coordinator reads the actual source, changes and original output, and checks every acceptance criterion. When the task requires a real user workflow, include verification of that workflow.

Completion refers to the current artifact version. The delivery explains what changed, what was verified, where the evidence is and what still needs follow-up. Clean up task-owned processes and browsers as part of delivery.

## Getting started

### Runtime requirements and package contents

The skill targets Windows and macOS. Prepare dependencies for the current operating system; both use the same roles, project commands and collaboration workflow. Public commands require **PowerShell 7.4+**. Windows projects use NTFS; macOS also requires **Python 3.11+**. Project setup adds collaboration rules, command scripts, tool configuration, task templates and runtime records.

Scripts select the process-management and backup implementation for the current operating system. Roles and workflow remain the same. Platform details and verification progress are recorded in [Validation](references/validation.md).

The current version has undergone isolated Windows regression testing. macOS has a platform implementation awaiting real-machine validation; automatic cleanup acceptance for multi-process CLIs still needs further work.

Models and execution tools are configured per project. The coordinator selects ready tools based on capability, quality requirements, cost, availability and user preferences. Start with the [tool configuration example](examples/tools.json) and use the [tool integration contract](references/tools.md) to define entry points and role capabilities.

| File or directory | Purpose |
|---|---|
| `SKILL.md` | Skill instructions and execution entry point |
| `SKILL.en.md` / `README.en.md` | English skill instructions and project introduction |
| `assets/diagrams/` | Chinese and English architecture and workflow diagrams |
| `references/` | Detailed setup, development and handoff guidance |
| `scripts/Initialize-Project.ps1` | Plan and apply project setup, or roll back from backups |
| `assets/project/` | Rules, commands and templates installed into a project |
| `agents/openai.yaml` | Client display metadata |
| `examples/tools.json` | Example tool and model configuration |
| `tests/` | Local verification scripts and deterministic test workers |

### Set up collaboration in a new project

In the target project's conversation, ask:

> Use $multi-model-collaboration to prepare a multi-model collaboration setup plan for this project.

The coordinator reads [Project onboarding](references/onboarding.md), identifies the root, runs the initializer's `Plan`, and presents the file list, expected effect, validation and rollback arrangements. After approval, run `Apply`, preserve originals and setup records, inspect project status and verify tools through the onboarding procedure.

### Develop in a configured project

Describe the development goal directly:

> Use $multi-model-collaboration to implement order filtering in this project. Establish acceptance criteria first, then organize implementation and independent testing.

The coordinator reads the rules and command README referenced by the project's `AGENTS.md` in full, then runs from the project root:

```powershell
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Status
pwsh -NoProfile -File scripts/collaboration/Collab.ps1 Doctor
```

`Status` reports task and runtime state; `Doctor` checks configuration and tool entry points. Follow the [project workflow](references/workflow.md) to create tasks, dispatch work, test and accept results. Read the project's `.agents/collaboration/README.md` and relevant templates for exact invocation parameters.

## Handoffs and efficient context

Prepare material for the assigned role: requirements, relevant source and write scope for executors; acceptance criteria, implementation and boundary cases for testers; the plan or changes and supporting evidence for reviewers.

A handoff includes six kinds of information:

1. **Identity:** task, role, invocation and instance.
2. **Goal:** the issue, file scope and acceptance criteria.
3. **Version:** current file digest and the applicable plan or result digest.
4. **Material:** necessary source, project rules, existing artifacts and evidence paths.
5. **Progress:** completed work, new findings and unresolved issues.
6. **Delivery:** expected artifacts, verification results and evidence locations.

Dispatch a complete intended outcome, including acceptance criteria, role scope and blockers to report. Workers finish the relevant work and checks, then return their results. Rechecks follow relevant changes, failures or conflicting evidence. The coordinator uses existing results to choose the next action and queries status to resolve specific uncertainties.

Reference accessible authoritative files for stable context. Rework adds the delta and material needed for the current round. Extract decisive command results first and open original records when needed for a decision. This reduces tokens spent copying, translating and summarizing the same information.

Dispatch briefs and worker responses use English; user-facing delivery uses Chinese. Keep code identifiers unchanged. For dispatch and rework, read [Handoffs and context management](references/handoff.md) and check actual invocation identity, valid versions and operations allowed in the current state.

`PrepareContext` assembles the current brief, role focus, acceptance criteria, delta and evidence locations into a context package. Source and stable background remain path-and-digest references. `Invoke` uses `ContextId` to check role, revision and referenced files. Regenerate the relevant context package when its materials change.

## Rework and evidence continuity

The coordinator records repair attempts and verification results under the same issue ID. **After two consecutive rounds without substantive progress on the same issue, stop related automatic dispatch and explain the blocker.** Progress requires evidence, such as a smaller failure scope, a resolved blocker or a new diagnosis supporting a different repair approach. Switching models, `Handoff`, `Rework` or a new task ID preserves the issue's history.

Report both rounds' results, evidence and conditions needed to continue. Resume dispatch on the user's explicit continuation instruction. Unsatisfied acceptance criteria remain unpassed; non-blocking suggestions do not trigger rework. See [Repair thresholds and stopping conditions](references/handoff.md#修复阈值与停止条件) for how rounds and progress are assessed.

`Rework` increments `revision` within the same task. Preserve a valid plan review while the plan remains applicable. When the plan changes or its review fails, supply a revised `PlanFile` and obtain another plan review. Each round needs independent testing and acceptance evidence; important tasks also need a fresh result review. Preserve historical invocations, plans and original backups.

For additional verification or changes limited to tester-owned files, the coordinator may use `ReuseImplementationFrom` to reference a valid implementation invocation. The runtime checks the plan revision, unchanged executor-owned files and intact invocation evidence, then starts independent testing in the new revision. Acceptance and important-task result reviews still belong to that revision.

After a normal invocation failure is continued through `Handoff` and current acceptance is met, directly `Complete` the current revision. If a concrete new testing issue is found before completion, a new rework round may reuse an unchanged implementation. New issues after completion use linked tasks. Implementation changes and incidents handled by `RecoverTask` proceed through implementation and verification. See [Rework and role context](references/iteration.md) for eligibility.

Acceptance registration saves an independent copy of the submitted file inside the task and records its source path and digest. When the tester regenerates a report within scope, historical acceptance still points to the saved copy. The coordinator inspects the current result before registering current evidence.

When a legacy record points directly to the original report path, preserve that original in place. Write the new report to a newly authorized path or the task inbox and register it there. See [Using legacy evidence](references/handoff.md#旧版证据继续使用).

## Tool selection and failure continuation

The coordinator selects models and execution tools based on required capability, quality, cost, availability and user preferences. Project configuration stores tools, model arguments and role capabilities; `preferenceOrder` defines a project-specific order. Invocation records distinguish the requested model from the model actually reported. Missing actual-model information is recorded as `unknown`.

Tool integrations share the same role and acceptance requirements; adapters translate arguments and output. The same model may fill different roles through independent sessions. All calls record `InstanceId`. The generic JSON adapter also returns the actual session ID, which the runtime checks for reuse across tools. Native CLI session independence is verified during integration and checked by the coordinator using arguments and original logs. See [Tool integration](references/tools.md).

When a call fails, the coordinator collects logs and changes, checks process cleanup and partial work, then selects the next tool and fresh instance according to task state. For incidents, `RecoverTask` verifies the recovery report, recorded process exits, restoration of out-of-scope files and original backups. It preserves the failure record and adds a recovery record. Then `Rework` begins a new revision with implementation, independent testing and required reviews. Restore missing process identity or critical records and the affected state before recovery verification.

Normal invocation failures with complete file and cleanup checks continue through `Handoff`. It captures the boundary of existing invocations and evidence and resets acceptance and real-workflow verification. Fresh instances of the appropriate roles address unresolved failures. Consecutive handoffs verify and retain successful replacements whose files and originals remain valid. Each handoff requires independent testing of the current version, new acceptance and required result review. Deliver once completion conditions are met; concrete repair issues use `Rework` for a new round. Preserve original failure records.

## File scanning and long-term use

Register an invocation after its prelaunch scan completes. An interrupted postlaunch scan remains pending verification; recovery uses the saved prelaunch baseline to compare the complete scope again. `Handoff` and `Rework` use valid recovery records to assess historical cleanup. `RecoverLock` handles stale project locks. `Status` shows recovery-mutex ownership; the operating system releases the handle when its process exits.

Each invocation checks project files and collaboration control records separately. The project inventory skips `.collaboration/`; a separate control snapshot checks historical calls, backups, evidence and inventories. New inventories describe current project files, with historical snapshots stored separately.

Projects can list derived directories in `protocol.inventory.exclude`, such as `node_modules/**` and `coverage/**`. Named task files, frozen tests and protected collaboration files remain checked. See [Recovery, scanning and role boundaries](references/recovery.md).

Control snapshots retain separate digests for filenames differing by case and use project-relative paths. Every invocation saves a digest-bound `baseline.json` for incident recovery.

## References by task

The detailed references and project command documentation are currently in Simplified Chinese.

| Current work | Reference |
|---|---|
| Plan, apply or roll back project setup | [Project onboarding](references/onboarding.md) |
| Develop, test, review and accept work in a configured project | [Project workflow](references/workflow.md) |
| Prepare dispatch, collect results, organize rework and reduce context | [Handoffs and context management](references/handoff.md) |
| Repair within a task, reuse valid implementation and prepare role context | [Rework and role context](references/iteration.md) |
| Configure models, CLIs and generic adapters | [Tool integration contract](references/tools.md) |
| Handle incidents, configure directory exclusions and assign test writes | [Recovery, scanning and role boundaries](references/recovery.md) |
| Check Windows and macOS verification progress | [Validation](references/validation.md) |
