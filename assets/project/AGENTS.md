<!-- MULTI-MODEL-COLLABORATION:BEGIN -->
## Multi-model collaboration

Read [COLLABORATION.md](COLLABORATION.md), [COLLABORATION-SETUP.md](COLLABORATION-SETUP.md), and the [command reference](.agents/collaboration/README.md) before collaborative development.

The main conversation coordinates requirements, plans, dispatch, evidence and acceptance. Independent executor, tester and reviewer instances perform their assigned work. Use the project command facade for task operations and bind each call to the current subject digest.

Declare tester-owned files with `TesterWritePath` when creating the task. After incident handling, use `RecoverTask` to verify evidence and enter a new revision through `Rework`.

Use `Rework` for a new revision and `PrepareContext` for role-specific briefs and references. `ReuseImplementationFrom` can carry an accepted implementation into validation when its plan and implementation files are unchanged and its evidence is intact. Independent testing, acceptance and required result review belong to the current revision. Incident recovery uses fresh implementation.

Use `Handoff` to continue a clean invocation failure within the current revision. Consecutive handoffs retain verified replacement work whose originals and subject remain valid. Complete the current revision once fresh independent validation, acceptance and required review pass. Before completion, start `Rework` when a concrete new repair round is needed; after completion, create a linked task for new issues.

Dispatch a complete role outcome with acceptance criteria and blocker conditions. Finish the assigned work and checks, then report the outcome and decisive evidence. Repeat checks after relevant changes, failures or evidence conflicts. Keep issue IDs across handoffs and attach dispositions and verification evidence.

For the same issue, stop related automatic dispatch after two consecutive repair rounds without substantive progress. The coordinator tracks attempts and verification evidence across handoffs, rework, model changes and linked tasks, following the repair stopping rules in COLLABORATION.md. Report the blocker, both rounds' results and what is needed to continue; resume dispatch on the user's explicit continuation instruction. Record non-blocking suggestions as dispositions or backlog items; they do not trigger rework.

Begin with `Status` and `Doctor`. Select models and tools from project configuration according to role capability and the user's preferences. Follow the user's current phase and file scope, prepare backups before implementation, and verify current results before completion.
<!-- MULTI-MODEL-COLLABORATION:END -->
