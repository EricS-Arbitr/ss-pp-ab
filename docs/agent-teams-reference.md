# Agent Teams — Master Reference Guide

> A working reference for coordinating multiple Claude Code sessions as a team.
> Source: https://code.claude.com/docs/en/agent-teams (behavior as of v2.1.178+).
> Purpose: help build **better and more effective agent teams**.

---

## 0. TL;DR — the decision in one screen

**Use an agent team when workers must talk to each other.** Otherwise reach for subagents or a workflow.

| You want…                                                        | Use               |
| :--------------------------------------------------------------- | :---------------- |
| Quick, focused helpers that just report a result back            | **Subagents**     |
| Deterministic fan-out/loops/pipelines with a fixed structure     | **Workflow tool** |
| Independent workers who share findings, challenge each other, self-coordinate | **Agent team** |
| A single sequential change, same-file edits, tightly-coupled work | **One session**  |

**Sweet spot:** research, parallel review, competing-hypothesis debugging, cross-layer features. Start with **3–5 teammates**, **5–6 tasks each**, and **give each one a distinct lens** so they don't overlap.

**Prerequisite:** experimental and **disabled by default**. Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`.

---

## 1. What an agent team is

Multiple Claude Code instances working together:

- **One lead** (the main session) — coordinates, assigns tasks, synthesizes results. Fixed for the session's lifetime; cannot be transferred.
- **Teammates** — separate, fully independent Claude Code sessions, each with **its own context window**. They work on assigned tasks and **message each other directly**.
- **Shared task list** — work items teammates claim and complete.
- **Mailbox** — messaging between agents; messages deliver automatically (no polling).

The differentiator vs subagents: **teammates communicate with each other**, not just back to the lead. You can also message any teammate directly, bypassing the lead.

---

## 2. Agent teams vs subagents vs workflows

|                   | Subagents                          | Agent teams                              | Workflow tool                        |
| :---------------- | :--------------------------------- | :--------------------------------------- | :----------------------------------- |
| **Context**       | Own window; result returns to caller | Own window; fully independent          | Own window per agent()               |
| **Communication** | Report back to main agent only     | Teammates message each other directly    | No inter-agent messaging; script glues results |
| **Coordination**  | Main agent manages all work        | Shared task list, self-coordination      | Deterministic JS (loops/conditionals/fan-out) |
| **Best for**      | Focused tasks, result-only         | Discussion, challenge, collaboration     | Structured parallelism at scale      |
| **Token cost**    | Lower (summarized back)            | Higher (each teammate a full instance)   | Scales with agent count              |

Rule of thumb: **need discussion between workers → agent team. Need a fixed pipeline → workflow. Need a quick answer → subagent.**

---

## 3. Enabling

Add to `settings.json` (or export in shell):

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

Without this variable: no team is set up, no team directories are written, and Claude will not spawn or propose teammates.

> **Version note:** As of v2.1.178, spawning a teammate needs **no setup step** and cleanup is automatic on session exit. The old `TeamCreate`/`TeamDelete` tools and the `team_name` input are gone (the field is deprecated/ignored where it lingers).

---

## 4. Starting and controlling a team

### 4.1 Spawn in natural language

Describe the task + the teammates you want. Example that works well (three **independent** roles):

```text
I'm designing a CLI tool that helps developers track TODO comments across
their codebase. Spawn three teammates to explore this from different angles:
one on UX, one on technical architecture, one playing devil's advocate.
```

The lead populates the shared task list, spawns a teammate per perspective, has them explore, and synthesizes at the end.

### 4.2 Two ways teams form

- **You request teammates** — explicitly ask.
- **Claude proposes teammates** — if it judges the task benefits from parallel work, it suggests; **you confirm first**. Claude never spawns without approval.

### 4.3 Specify count and model

```text
Spawn 4 teammates to refactor these modules in parallel. Use Sonnet for each teammate.
```

- Teammates **don't inherit the lead's `/model`** by default. Set **Default teammate model** in `/config` (pick "Default (leader's model)" to follow the lead).
- Teammates **inherit the lead's effort level** (split-pane: v2.1.186+).

### 4.4 Require plan approval (for risky work)

```text
Spawn an architect teammate to refactor the authentication module.
Require plan approval before they make any changes.
```

Teammate stays in **read-only plan mode** until the lead approves. On rejection it revises and resubmits. The lead approves **autonomously** — steer it with criteria in your prompt, e.g. *"only approve plans that include test coverage"* or *"reject plans that modify the database schema."*

### 4.5 Talk to a teammate directly

Each teammate is a full session you can redirect.

- **In-process mode:** ↑/↓ in the agent panel to select → **Enter** to open its transcript and type a message. **x** stops a selected teammate. **Ctrl+T** toggles the task list. **Escape** interrupts its current turn.
- **Split-pane mode:** click into the teammate's pane.

### 4.6 Shut a teammate down

```text
Ask the researcher teammate to shut down
```

Lead sends a shutdown request; teammate can approve (exit gracefully) or reject with an explanation. Shared directories clean up automatically on session end.

---

## 5. Display modes

| Mode          | Behavior                                        | Requirements                          |
| :------------ | :---------------------------------------------- | :------------------------------------ |
| `in-process`  | **Default.** All teammates in the main terminal; navigate via agent panel | Any terminal, no setup |
| `auto`        | Split panes if inside tmux, or iTerm2 + `it2`; else in-process | tmux **or** iTerm2 + `it2` |
| `tmux`        | Split panes; auto-detects tmux vs iTerm2        | tmux or iTerm2                        |
| `iterm2`      | iTerm2 native split panes (v2.1.186+)           | `it2` CLI + Python API enabled        |

Set persistently in `~/.claude/settings.json`:

```json
{ "teammateMode": "auto" }
```

Or per session: `claude --teammate-mode auto`

**Gotchas:**
- Default changed to `in-process` in v2.1.179 (was `auto`). Upgraded sessions no longer auto-open split panes unless set explicitly.
- Split panes are **not supported** in VS Code's integrated terminal, Windows Terminal, or Ghostty.
- iTerm2: install `it2`, then enable **Settings → General → Magic → Enable Python API**. `tmux -CC` in iTerm2 is the suggested entrypoint.
- Idle teammate rows hide after 30s (v2.1.181+) and reappear on next turn — the teammate is still running and addressable.

---

## 6. The shared task list

- States: **pending → in progress → completed**.
- **Dependencies:** a pending task with unresolved deps can't be claimed until they complete. Unblocking is automatic when the dependency finishes.
- **Assignment:** lead assigns explicitly, **or** a teammate self-claims the next unassigned, unblocked task after finishing one.
- **Race safety:** task claiming uses **file locking** to prevent two teammates grabbing the same task.

---

## 7. Architecture & storage

| Component | Role |
| :-------- | :--- |
| Team lead | Main session; spawns teammates and coordinates |
| Teammates | Separate Claude Code instances doing assigned tasks |
| Task list | Shared, claimable work items |
| Mailbox   | Inter-agent messaging (auto-delivered) |

**Local storage** (session-derived name = `session-` + first 8 chars of session ID):

- Team config: `~/.claude/teams/{team-name}/config.json` — **removed when the session ends**.
- Task list: `~/.claude/tasks/{team-name}/` — **persists locally, never uploaded**; resumed sessions keep tasks. Retention follows `cleanupPeriodDays`.

**Do not hand-edit or pre-author the team config** — it holds runtime state (session IDs, tmux pane IDs) and is overwritten on the next state update. It contains a `members` array (name, agent ID, agent type) that teammates can read to discover each other. There is **no project-level team config**; a `.claude/teams/teams.json` in your repo is treated as an ordinary file, not configuration.

---

## 8. Reusable roles via subagent definitions

Reference a [subagent](https://code.claude.com/docs/en/sub-agents) type (project / user / plugin / CLI scope) when spawning:

```text
Spawn a teammate using the security-reviewer agent type to audit the auth module.
```

- The teammate honors that definition's **`tools` allowlist** and **`model`**.
- The definition's **body is appended** to the teammate's system prompt (additive, not a replacement).
- **`SendMessage` and task-management tools are always available**, even when `tools` restricts everything else.
- **Not applied as a teammate:** the `skills` and `mcpServers` frontmatter fields. Teammates load skills and MCP servers from project + user settings, like a normal session.

Define a role once, reuse it both as a delegated subagent and as a team teammate.

---

## 9. Context, communication & permissions

### Context each teammate gets
- Loads the same project context as a regular session: **CLAUDE.md, MCP servers, skills**.
- Receives the **spawn prompt** from the lead.
- **Does NOT** inherit the lead's conversation history → put all needed detail in the spawn prompt.

### How teammates share information
- **Automatic message delivery** — no polling needed by the lead.
- **Idle notifications** — a teammate that finishes/stops notifies the lead automatically.
- **Shared task list** — all agents see status and claim work.
- **Named messaging** — message one teammate by name; to reach everyone, send one message per recipient. Give teammates predictable names in your spawn prompt so you can reference them later.

### Permissions (security model)
- Teammates start with the **lead's permission settings** (incl. `--dangerously-skip-permissions`).
- You can change an **individual** teammate's mode after spawn, but **not per-teammate at spawn time**.
- Cross-agent messages are marked as coming **from another Claude session, not from you**. A teammate **cannot** approve a permission prompt or grant consent on your behalf, and **cannot relay** a denied action to another teammate to bypass a check. In auto mode, a relayed "it's approved" claim is treated as **untrusted input**.
- Teammate permission prompts **bubble up to the lead** — approve them there yourself. Pre-approve common ops in permission settings to cut interruptions.

---

## 10. Best practices (the part that makes teams actually good)

1. **Give each teammate a distinct lens.** Overlapping roles waste tokens. In review: security / performance / test-coverage. In debugging: one hypothesis each.
2. **Front-load context in the spawn prompt.** Teammates don't see the lead's history. Include files/paths, constraints, tech facts, and the expected deliverable + format. Example:
   > *"Review the authentication module at `src/auth/` for security vulnerabilities. Focus on token handling, session management, and input validation. The app uses JWT tokens stored in httpOnly cookies. Report any issues with severity ratings."*
3. **Right-size the team: 3–5 teammates** for most work. Token cost scales linearly; coordination overhead and diminishing returns rise with size. **Three focused teammates beat five scattered ones.**
4. **Right-size tasks.** Too small → coordination overhead dominates. Too large → long unsupervised runs risk wasted effort. Aim for **self-contained units with a clear deliverable** (a function, a test file, a review). Target **5–6 tasks per teammate**; 15 independent tasks ≈ 3 teammates.
5. **Make debugging adversarial.** Tell teammates to **challenge each other's theories** ("like a scientific debate"). This defeats anchoring — the surviving theory is far likelier to be the real root cause.
6. **Wait for teammates to finish.** If the lead starts doing tasks itself: *"Wait for your teammates to complete their tasks before proceeding."*
7. **Avoid file conflicts.** Two teammates editing one file → overwrites. **Partition files** so each teammate owns a disjoint set. Worktree isolation is the manual alternative.
8. **Monitor and steer.** Check progress, redirect dead ends, synthesize as findings arrive. Don't let a team run unattended too long.
9. **Start with research/review** if new to teams — clear boundaries, no parallel-write coordination. PR review, library research, bug investigation.
10. **Enforce quality with hooks** (see §11).

---

## 11. Quality gates via hooks

Exit code **2** in these hooks sends feedback and blocks the transition:

| Hook            | Fires when…                     | Exit-2 effect                              |
| :-------------- | :------------------------------ | :----------------------------------------- |
| `TeammateIdle`  | a teammate is about to go idle  | send feedback, **keep the teammate working** |
| `TaskCreated`   | a task is being created         | **prevent creation**, send feedback        |
| `TaskCompleted` | a task is being marked complete | **prevent completion**, send feedback      |

Use these to enforce "no task completes without passing tests," "reject out-of-scope tasks," etc.

---

## 12. Reusable prompt patterns

### Parallel code review (distinct lenses)
```text
Spawn three teammates to review PR #142:
- One focused on security implications
- One checking performance impact
- One validating test coverage
Have them each review and report findings.
```

### Competing-hypothesis debugging (adversarial debate)
```text
Users report the app exits after one message instead of staying connected.
Spawn 5 agent teammates to investigate different hypotheses. Have them talk to
each other to try to disprove each other's theories, like a scientific
debate. Update the findings doc with whatever consensus emerges.
```

### Cross-layer feature (file partitioning)
```text
Spawn 3 teammates to build feature X: one owns the frontend in src/ui/,
one owns the backend in src/api/, one owns tests in tests/. Keep to your
own directories to avoid conflicts. Coordinate the API contract between
frontend and backend before implementing.
```

### Gated architect (plan approval)
```text
Spawn an architect teammate to refactor the authentication module.
Require plan approval before they make any changes. Only approve plans
that include test coverage and don't modify the database schema.
```

---

## 13. Troubleshooting

| Symptom | Fix |
| :------ | :--- |
| **Teammates not appearing** | In-process: they're in the agent panel — ↑/↓ then Enter. Idle rows hide after 30s (still running) — message by name to surface. Confirm the task was complex enough to warrant a team. Split panes: `which tmux`; for iTerm2 verify `it2` + Python API. |
| **Too many permission prompts** | Pre-approve common ops in permission settings before spawning. |
| **Teammate stopped on an error** | Open its transcript (Enter / click pane); give more instructions, or spawn a replacement to continue. |
| **Lead shut down before work done** | Tell it to keep going; tell it to wait for teammates before proceeding if it's doing work itself. |
| **Orphaned tmux session** | `tmux ls` then `tmux kill-session -t <session-name>`. |
| **Task stuck / dependents blocked** | Teammate may have failed to mark it complete. Verify the work, update status manually, or tell the lead to nudge the teammate. |

---

## 14. Limitations (experimental — plan around these)

- **No session resumption with in-process teammates:** `/resume` and `/rewind` don't restore them. After resuming, the lead may message teammates that no longer exist → tell it to spawn new ones.
- **Task status can lag:** teammates sometimes don't mark tasks complete, blocking dependents. Check and fix manually.
- **Shutdown can be slow:** a teammate finishes its current request/tool call first.
- **One team per session**, scoped to that session. No additional named teams, no sharing across sessions.
- **No nested teams:** teammates can't spawn teammates. Only the lead manages the team.
- **Lead is fixed:** can't promote a teammate or transfer leadership.
- **Permissions set at spawn:** all start with the lead's mode; change individuals after, not per-teammate at spawn.
- **Split panes need tmux or iTerm2:** unsupported in VS Code integrated terminal, Windows Terminal, Ghostty.

---

## 15. Cost reality check

Each teammate is a **full Claude instance with its own context window** → token usage scales with active teammate count. Worthwhile for research, review, and new-feature work; wasteful for routine/sequential tasks. See the docs' [agent team token costs](https://code.claude.com/docs/en/costs#agent-team-token-costs) section for guidance. When in doubt: fewer, better-scoped teammates.

---

## 16. Quick checklist before spawning a team

- [ ] Is this experimental flag enabled? (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)
- [ ] Do the workers genuinely need to **talk to each other**? (If not → subagents/workflow.)
- [ ] Does each teammate have a **distinct, non-overlapping lens**?
- [ ] Is all needed context **in the spawn prompt** (no reliance on lead history)?
- [ ] Are **files partitioned** so no two teammates edit the same one?
- [ ] Is the team **3–5 teammates**, ~**5–6 tasks each**?
- [ ] For risky work: is **plan approval** required with clear approval criteria?
- [ ] Do I have **hooks** for quality gates if this needs to be enforced?
- [ ] Am I ready to **monitor and steer** rather than let it run unattended?

---

## 17. Related

- Subagents: https://code.claude.com/docs/en/sub-agents
- Git worktrees (manual parallel sessions): https://code.claude.com/docs/en/worktrees
- Hooks: https://code.claude.com/docs/en/hooks
- Settings: https://code.claude.com/docs/en/settings
- Feature comparison: https://code.claude.com/docs/en/features-overview#compare-similar-features
