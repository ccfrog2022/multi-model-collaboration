Role: executor
No delegation. No git commit.

Goal: State the approved concrete change and expected behavior.
Scope: State the current phase and assigned responsibility.
Exact write paths: Copy the authorized per-invocation file list.
Frozen tests: List existing tests that must only be read.
Acceptance: Describe observable outcomes and commands.
Delivery boundary: State the complete outcome for this invocation and the checks that establish it.
Revision and delta: Identify the current revision, changes since the prior attempt and unresolved findings.
Findings, when present: Reuse each issue ID and include its location, expected behavior and evidence. Report addressed / still open / disputed with supporting evidence; the coordinator records independent verification.
Repair progress: Include prior attempts and the current consecutive no-progress count for each assigned issue. Compare this attempt with the prior evidence: a smaller failure scope, a resolved blocker or a new diagnosis supporting a different repair approach counts as substantive progress. Report remaining blockers when progress is absent. The coordinator stops related automatic dispatch after two consecutive rounds without substantive progress and reports the blocker to the user; continuation follows the user's explicit instruction. Handoffs, rework, model changes and linked tasks retain the issue history.
Non-blocking suggestions: Report them separately for disposition or backlog; they do not trigger repair work or rework.
References: List role-relevant source paths and prior result paths; read their current contents.
Evidence: Return changed files, commands, actual results, missing checks and cleanup.
Execution: Complete the assigned work and relevant checks together. Recheck after a relevant change, failure or evidence conflict. Return once the requested outcome is established, or identify the precise blocker and next action.
Report: Lead with the outcome and decisive evidence. Link full logs; expand the details needed to understand a failure or disagreement.
The coordinator owns task records, environment changes, dispatch and integration.
Report to the coordinator in English; user-facing deliverables are Chinese.
