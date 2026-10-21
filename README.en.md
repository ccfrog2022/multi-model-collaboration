# Multi-Model Collaboration

[简体中文](README.md) | **English**

**A software development skill that improves delivery quality through independent verification.**

The main conversation coordinates requirements and tasks. Executors implement code, testers verify it independently, and reviewers examine plans and results. Every stage works toward shared acceptance criteria, with task identities, current versions and original evidence supporting each handoff.

## Why use it

- **Clear responsibilities:** coordination, implementation, testing and review have distinct deliverables.
- **Independent verification:** ordinary tasks receive independent testing; important tasks add plan and result reviews.
- **Traceable handoffs:** each invocation records its task, instance, model, artifact version and evidence.
- **Less repeated context:** prepare material by role, reference stable background and pass deltas during rework.
- **Continuous rework:** record revisions within the same task, preserve historical evidence and verify repairs.
- **Incident recovery:** verify the recovery evidence and affected state, append a recovery record, then start a new implementation and verification round.
- **Role-specific write scope:** define tester-owned files at task creation so executors and testers maintain their own artifacts.
- **Configurable models:** choose models and execution tools per project, including role capabilities and preferences.
- **One cross-platform workflow:** Windows and macOS use the same roles and task, testing, review and acceptance commands.

Read [SKILL.en.md](SKILL.en.md) for a complete introduction to the workflow.

[View the architecture and workflow diagram](assets/diagrams/architecture-workflow.en.png).

## Complete package

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

The entire directory is one skill. The initializer copies commands, rules and templates from its bundled `assets/project/`; all supporting sources are included. Preserve the hidden `.agents` directory when uploading or copying the package.

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

## Quality and handoffs

Every implementation task receives independent testing of the current version. Important tasks receive independent reviews of both plan and result. The coordinator checks original artifacts and evidence against each acceptance criterion.

Prepare context by role and link task summaries to detailed evidence. During rework, pass the delta and current issues first. Model selection and reasoning parameters carry the project's cost tradeoffs while independent testing and required reviews remain in place.

`Rework` starts the next repair round within the same task. For additional verification or changes limited to test files, an accepted, unchanged implementation may be reused to proceed directly to independent testing. The new revision still requires its own acceptance and necessary reviews. `PrepareContext` creates role context packages bound to revisions and file digests. See [Rework and role context](references/iteration.md).

Acceptance registration saves an independent copy of the submitted file and its source information. Fixed-path test reports can be regenerated within the task scope while historical acceptance continues to reference the preserved content.

Dispatch briefs state the complete deliverable, acceptance criteria and blockers to report. Workers complete their assigned work and relevant checks before returning. Short issue IDs connect dispositions to verification evidence. Responses lead with the conclusion and decisive evidence, expanding details for actual issues. Rechecks follow relevant changes, failures or conflicting evidence.

The coordinator records repair attempts and verification results for the same issue. After two consecutive rounds without substantive progress, stop related automatic dispatch and explain the blocker, both rounds' evidence and the conditions needed to continue. Resume dispatch on the user's explicit continuation instruction. Handoffs, rework and model changes retain the issue history. Record non-blocking suggestions as dispositions or backlog items; they do not trigger rework. Deliver when acceptance is met and blockers are closed. See [Repair thresholds and stopping conditions](references/handoff.md#修复阈值与停止条件).

## Recovery and scan configuration

For scope violations or uncertain cleanup, the coordinator handles the affected state and prepares specific evidence. `RecoverTask` registers the verification, and `Rework` starts a new revision. Preserve original failure, violation and cleanup records; recovery records bind their digests and evidence.

Normal invocation failures with complete file and cleanup checks continue through `Handoff` in the current revision. Consecutive handoffs retain successful replacements whose originals, plan and applicable file digest remain valid. The appropriate roles address unresolved failures. Each handoff requires independent testing, new acceptance and required result reviews. Then directly `Complete` the revision.

Before completion, a concrete new repair issue may use `Rework`; test-only rework can reuse eligible unchanged implementation. New issues after completion use linked tasks.

New acceptance records save independent evidence copies. For legacy records pointing directly to a source report, preserve the original at its path and write the new report to an authorized new path or the task inbox before registration. See [Handoffs and legacy evidence](references/handoff.md).

If a prelaunch scan fails, correct the configuration or file conditions before retrying. If a postlaunch scan is interrupted, recovery verification reads the bound prelaunch baseline and checks the complete changes again. Recovered tasks continue through the same implementation, independent testing, handoff and acceptance workflow.

`RecoverLock` handles stale project locks. Recovery uses operating-system handle-based mutual exclusion; the handle is released when the process exits. `Status` reports both the project lock and recovery mutex. File ownership checks use identity at task creation and invocation, accounting for actual files and filesystem case rules on macOS.

Project inventories and collaboration control snapshots check different parts of the project. Historical records retain integrity checks, while project inventories describe source and other project files. Derived-directory exclusions reduce dependency and generated-file scanning; task files, frozen tests and collaboration controls remain checked. See [Recovery and scanning](references/recovery.md) for configuration examples.

## Local verification

Run from the skill root:

```powershell
pwsh -NoProfile -File tests/Test-Package.ps1 -Python /absolute/path/to/python
```

Set `-Python` to the local interpreter path. When omitted, Windows looks for `python` and macOS for `python3`. Tests use a new isolated directory to verify setup, rollback, ordinary and important tasks, version and independence checks, interrupted-scan recovery, post-recovery handoffs, lock concurrency and process cleanup. They print the record location. [Validation](references/validation.md) distinguishes platform tests from simulated checks.

## Further reading

The detailed references and project command documentation are currently in Simplified Chinese.

- [Complete skill guide](SKILL.en.md)
- [Onboarding and rollback](references/onboarding.md)
- [Development, testing and acceptance](references/workflow.md)
- [Handoffs and context](references/handoff.md)
- [Rework and role context](references/iteration.md)
- [Tool integration contract](references/tools.md)
- [Recovery, scanning and role boundaries](references/recovery.md)
- [Validation](references/validation.md)
