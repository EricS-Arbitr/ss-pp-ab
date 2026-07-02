# Agent Teams — Patterns, Use Cases & Gaps

> Companion to [agent-teams-reference.md](agent-teams-reference.md). Where the reference is the raw
> spec, this document is the **applied** layer: verified configuration, domain-general use-case
> patterns, and an honest accounting of what the reference still can't answer.
>
> Produced by the `research-team` (Researcher + Strategist + Critic, Sonnet 5), synthesized by the lead.
> Scope note: `fuel-farm-build-sheet.md` was intentionally excluded — use cases are drawn from general
> software-engineering work, not any single repo.
> Source of truth: [agent-teams-reference.md](agent-teams-reference.md) → https://code.claude.com/docs/en/agent-teams (v2.1.178+).

---

## Configuration Reference

*(from the Researcher — a structured inventory of every knob, verified against the reference doc and this repo. This workspace's `.claude/settings.local.json` already sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, so teams are live here.)*

### A. Settings & environment

| Key | Location | Purpose | Values / default |
| :-- | :------- | :------ | :--------------- |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `env` in `settings.json` or shell | Master enable switch | `"1"` enables; **off by default**. Without it, no team forms and no teammates spawn. |
| `teammateMode` | `~/.claude/settings.json` | Display mode | `"in-process"` (default since v2.1.179), `"auto"`, `"tmux"`, `"iterm2"` |
| **Default teammate model** | `/config` menu | Model for new teammates | A specific model, or "Default (leader's model)". Teammates do **not** inherit `/model` otherwise. |
| `cleanupPeriodDays` | settings (shared with transcripts) | Task-list retention window | ⚠️ default/units/location not stated in source — see Gaps |
| `team_name` | — | Legacy naming | **Deprecated/removed** (v2.1.178). `TeamCreate`/`TeamDelete` tools gone; no setup step needed. |

### B. CLI flags

- `--teammate-mode <in-process|auto|tmux|iterm2>` — per-session display-mode override.
- `--dangerously-skip-permissions` — not teams-specific, but **inherited by every teammate at spawn**.

### C. Hooks (quality gates)

Exit code **2** blocks the transition and sends feedback:

| Hook | Fires when… | Exit-2 effect |
| :--- | :---------- | :------------ |
| `TeammateIdle` | teammate about to go idle | keep it working |
| `TaskCreated` | task being created | block creation |
| `TaskCompleted` | task being marked complete | block completion |

Use to enforce "no task completes without passing tests," "reject out-of-scope tasks." ⚠️ Payload schema and repeat-exit-2 behavior are undocumented — see Gaps.

### D. Display modes

| Mode | Behavior | Requirements |
| :--- | :------- | :----------- |
| `in-process` | **Default.** All teammates in main terminal; agent-panel navigation | Any terminal |
| `auto` | Split panes if in tmux / iTerm2+`it2`, else in-process | tmux **or** iTerm2 + `it2` |
| `tmux` | Split panes; auto-detects tmux vs iTerm2 | tmux or iTerm2 |
| `iterm2` | iTerm2 native split panes (v2.1.186+) | `it2` CLI + Python API enabled |

**Unsupported for split panes:** VS Code integrated terminal, Windows Terminal, Ghostty. Idle rows hide after 30s (v2.1.181+) — teammate still runs; message by name to resurface. In-process controls: ↑/↓ select, **Enter** open/message, **x** stop, **Ctrl+T** toggle task list, **Esc** interrupt.

### E. Permissions

- Teammates inherit the **lead's** permission settings at spawn (including `--dangerously-skip-permissions`).
- You can change an **individual** teammate's mode *after* spawn, **not** per-teammate at spawn. ⚠️ The actual mechanism is undocumented — see Gaps.
- Cross-agent messages are tagged "from another Claude session, not from you." A teammate **cannot** approve prompts, grant consent, or relay a denied action to bypass a check; relayed "it's approved" claims are treated as untrusted.
- Teammate permission prompts **bubble up to the lead** — approve there. Pre-approve common ops to reduce friction.

### F. Storage (team name = `session-` + first 8 chars of session ID)

| Component | Path | Persistence |
| :-------- | :--- | :---------- |
| Team config | `~/.claude/teams/{team-name}/config.json` | **Deleted at session end.** Holds runtime state + a `members` array (name/agent-ID/agent-type). Never hand-edit. |
| Task list | `~/.claude/tasks/{team-name}/` | **Persists locally, never uploaded.** Resumed sessions keep tasks; retention via `cleanupPeriodDays`. |

No project-level team config exists; a repo `.claude/teams/teams.json` is treated as an ordinary file.

### G. Task management

States **pending → in progress → completed**. Dependencies: blocked tasks are unclaimable until deps complete, then auto-unblock. Assignment: lead assigns **or** teammate self-claims the next unblocked task. **File locking** prevents claim races. ⚠️ Known lag: teammates sometimes fail to mark complete, blocking dependents.

### H. Spawning & role reuse

Natural-language spawning; Claude may propose teammates (user confirms). **Plan-approval gating** keeps a teammate read-only until the lead approves (steerable via criteria). Reusing a **subagent definition** as a teammate:

| Frontmatter field | Applied? |
| :---------------- | :------- |
| `tools` allowlist | ✅ honored |
| `model` | ✅ honored |
| body (system prompt) | ✅ **appended** (additive) |
| `skills` | ❌ loaded from project/user settings instead |
| `mcpServers` | ❌ loaded from project/user settings instead |

`SendMessage` + task-management tools are **always available**, even under a restrictive `tools` allowlist.

### I. Context & communication

Teammates load CLAUDE.md, MCP servers, skills, and the spawn prompt — but **not** the lead's conversation history (front-load everything). Mailbox auto-delivers (no polling). Idle notifications go to the lead. **Named messaging is one-message-per-recipient — there is no broadcast.** Give teammates predictable names.

### J. Limitations

No in-process teammate resumption (`/resume`, `/rewind` don't restore them) · task-status lag · slow shutdown · one team per session · no nested teams · fixed lead · permissions set at spawn · split panes need tmux/iTerm2 · token cost scales linearly with active teammates.

---

## Use Case Patterns

*(from the Strategist — 5 domain-general scenarios. The Critic's verdict on each is folded in as a ⚖️ note, including whether a team is truly justified over subagents.)*

### Pattern 1 — Multi-lens code review of a large PR
**Scenario:** A 2,400-line PR adds a billing subsystem to a Rails + React monorepo (migrations, service layer, REST endpoints, dashboard). Policy requires correctness, security, performance, and test-coverage review before merge.
**Structure:** 4 read-only reviewers — correctness (`app/services`, `app/models`), security (`app/controllers`, `config`, auth), performance (migrations + query patterns), frontend/test (`client/src/billing`, specs). Reuse `code-reviewer`/`security-review` subagent defs. Sonnet; high effort for correctness/security, medium for the rest. A cross-check task blocked on correctness + security completing.
**Workflow:** Lead front-loads each reviewer with the diff summary, rubric, and file scope; reviewers work partitions in parallel writing findings to task entries (not editing the PR); security pings correctness directly on a shared concern; cross-check unblocks when both finish; lead posts one consolidated review.
⚖️ **Critic cautions:** (1) **Weakest team justification of the five** — independent findings synthesized at the end is the *subagent* pattern unless cross-lens discussion is genuinely load-bearing. (2) A `TaskCompleted` gate on "findings > 0" is a **logic bug** — a clean lens can never satisfy it; gate on "findings *reported*" instead. (3) The 2-way cross-check join can silently deadlock on the task-lag bug.

### Pattern 2 — Live production incident war room
**Scenario:** A checkout API (Node/Postgres/Kafka) throws 500s at 2am; on-call triages with a team while paging humans.
**Structure:** 3 teammates — mitigation (low/medium effort, "stop the bleeding"), root-cause (high effort, logs/traces/commits), scribe (Haiku or low-effort Sonnet, running timeline). Destructive actions bubble to the lead via plan-approval. Postmortem task blocked on mitigation + root-cause.
**Workflow:** Lead front-loads all three with the alert + dashboards; root-cause finds a recent deploy and messages mitigation directly with the exact feature-flag to flip; mitigation asks the lead to approve the one command; scribe updates the timeline off idle notifications; postmortem unblocks when both leaf tasks finish.
⚖️ **Critic cautions:** (1) **Lead-approval bubbling is a latency bottleneck exactly when speed matters** — weigh against a pre-approved runbook. (2) "Mitigation complete" has **no natural end** during an ongoing incident → postmortem can block forever; define a bounded done-condition ("stable for N min"). (3) Spawn + context-loading 3 teammates has real setup cost; for short incidents, working it solo may be faster.

### Pattern 3 — Competing-hypothesis debugging *(strongest team fit)*
**Scenario:** A Go + Redis + Postgres scheduler intermittently double-processes jobs (~1 in thousands). Three culprits: Redis lock-TTL race, Postgres isolation, retry-queue idempotency.
**Structure:** 3 hypothesis owners, each scoped to a disjoint package (`internal/lock`, `internal/store`, `internal/queue`), each mandated to produce a minimal repro **or** a concrete disproof. Sonnet, high effort. Independent tasks (any could be true).
**Workflow:** Lead front-loads identical incident context + "definition of done"; owners investigate and message each other to rule theories in/out in real time; disproof is a valid completion; team converges; lead assigns the fix to the owner with the most context and reconstructs the elimination trail from the message log.
⚖️ **Critic cautions:** (1) Three *fixed* hypotheses leave **no path for a cause outside the set** (goroutine leak, bad channel close) and no guard against social convergence on a wrong shared answer — instruct the lead to allow a new hypothesis mid-run. (2) "Converge then fix" has **no arbiter or termination condition**; debate can accrue linear token cost past the point a serial engineer would've finished.

### Pattern 4 — Cross-layer feature build *(edit-conflict risk)*
**Scenario:** "Saved searches with email alerts" on a marketplace monorepo — Postgres schema, notification job, GraphQL API, React Native UI.
**Structure:** 4 layer owners (schema / API / notifier / mobile). Dependency graph: **schema → {API, notifier} → mobile**. `TaskCompleted` hook requires migrations run clean.
**Workflow:** Lead defines the dependency graph before spawning and front-loads each owner with the design doc + file boundaries; schema runs first; API and notifier unblock together on disjoint files; API messages mobile the finalized resolver shape early so it can scaffold; mobile unblocks on API completion; lead runs an integration pass.
⚖️ **Critic cautions:** (1) **Reproduces the anti-pattern the reference warns against** — API and mobile both touch the shared `schema.graphql`, "resolved by the lead" is an acknowledgment, not a protocol. Use single-writer ownership (see Gaps → shared-artifact pattern). (2) Concurrent migrations against one shared test DB produce **flaky hook failures** that look like feature bugs.

### Pattern 5 — Monorepo dependency-upgrade blitz *(coupling risk; weakest cost case)*
**Scenario:** React 17→18 + Node 18→20 across 25 packages (shared UI lib, 6 frontends, 4 backends, tooling).
**Structure:** 5 teammates (top of the sweet spot) — shared-UI-lib (goes first, true upstream dep), frontend-A (3 apps), frontend-B (3 apps), backend (4 services), tooling/CI (sole owner of lockfile + CI matrix). Sonnet, mostly medium effort. `TaskCompleted` hook requires package tests pass.
**Workflow:** Lead front-loads target versions + breaking-changes summary + exact package list per teammate; UI lib lands first and messages each frontend teammate individually with the `createRoot` codemod; downstream teammates work disjoint package dirs in parallel; tooling regenerates the lockfile once at the end.
⚖️ **Critic cautions:** (1) **"Sole lockfile owner" moves the race, doesn't remove it** — the lockfile is a graph-level artifact regenerated from every `package.json`; if siblings are still editing pins, tooling works off a moving target. (2) The design's "message each affected peer" **contradicts the no-broadcast limitation** and degrades to lead-relay; budget for it. (3) **Shared root config (tsconfig/eslint/CI YAML) has no owner** — unassigned-file gap. (4) **Weakest cost justification** — layers aren't actually independent (lockfile + shared config couple them), so the team pays full linear cost for coordination it can't cleanly parallelize; a scripted workflow or one sequential session may win.

### Cross-cutting sizing guidance
3–5 teammates, ~5–6 tasks each, each with a **distinct lens**. Token cost scales linearly, so every teammate must earn its context window. **A team is only worth it when a teammate needs another teammate's *live, mid-task* output** — not merely its finished result (subagents already give you that). By the Critic's read, only Patterns 2, 3, and 4 have a genuine architectural need for live peer messaging; Patterns 1 and 5 are plausibly cheaper as subagent fan-out or a scripted workflow.

---

## Gaps and Recommendations

*(from the Critic — what the reference names but doesn't make actionable, plus what's missing entirely. Items marked ⚠️ are unresolved in the source and need verification against live docs before relying on them.)*

### Under-documented configuration (resolve before scripting against these)

1. ⚠️ **`cleanupPeriodDays`** — named, never specified: no default, no confirmed units (wall-clock days vs session count), no config location, no expiry behavior (delete vs archive). A citation, not documentation.
2. ⚠️ **Orphaned tasks after `/resume` = silent deadlock** — a task left "in progress" under a teammate that resume can't restore can never reach "completed," so dependents block forever with no notification. The doc splits this across two sections and never states the causal chain.
3. ⚠️ **Session-name stability on resume** — team/task dirs are keyed to the session ID; if resume mints a new ID, the old task directory is orphaned and unreachable. Never addressed. Compounds #2.
4. ⚠️ **Per-teammate permission-mode change** — asserted twice ("change individual modes after spawn"), defined nowhere. No command, keystroke, or gesture given. The single worst actionable gap.
5. ⚠️ **Max team size / concurrency cap** — 3–5 is a *recommendation*; unknown whether a hard ceiling exists or what happens past it (reject / queue / degrade).
6. ⚠️ **Per-teammate token/cost visibility** — "monitor cost" is implied, but no in-session instrument (no `/cost`-equivalent, nothing in the agent panel) is described.
7. ⚠️ **Hook payload schema** — hooks are named and their exit-2 effect given, but the data delivered (task ID? teammate? findings? diff?) is absent, so the gating hooks 3 of 5 patterns rely on aren't implementable from the doc.
8. ⚠️ **Repeat-exit-2 behavior** — if a `TaskCompleted` hook keeps failing (tests never pass), is there a retry cap, escalation, or infinite loop? Undefined.
9. ⚠️ **Model precedence** — `/config` default teammate model (§4.3) vs a subagent definition's `model` (§8): which wins when both are set? Presented separately, never reconciled.
10. ⚠️ **Effort-level inheritance for in-process teammates** — called out only for split-pane (v2.1.186+); silent on whether in-process inherits effort at all (and model explicitly does *not* inherit by default, so readers can't assume).
11. ⚠️ **`auto` mode tie-break** — which wins when both tmux and iTerm2+`it2` are available.

### Hidden pitfalls (design around these)

- **Deadlock on the task-lag bug:** Patterns 1, 2, 4 build blocking joins directly on the doc's most-cited risk. Pair every hard-dependency task with a `TaskCompleted` evidence gate **and** a lead-side stall watchdog.
- **Gate logic bugs:** "findings > 0" (Pattern 1) is unsatisfiable for a clean lens; gate on "reported," not "non-empty."
- **Unbounded tasks block dependents:** "mitigation complete" (Pattern 2) and "converge" (Pattern 3) need explicit done-conditions or dependents hang forever.
- **Shared-artifact overwrite:** the GraphQL schema (Pattern 4) and the lockfile + root config (Pattern 5) are shared/graph-level state that file-partitioning can't fix. Needs a single-writer protocol.
- **No-broadcast tax:** any "teammate tells all affected peers" design (Pattern 5) degrades to lead-relay; budget the extra hops.

### What to add to the reference docs (prioritized)

**Must-fix**
1. **Failure-recovery playbook** — how to inspect `~/.claude/tasks/{team}/`, find tasks stuck under a dead teammate, reset status, and reattach a replacement to *existing* tasks. Highest-value addition (resolves #2, #3).
2. **`cleanupPeriodDays` full spec** — default, units, location, expiry behavior.
3. **Hook payload schema + repeat-exit-2 behavior**, with one worked example (a `TaskCompleted` hook that runs tests and exits 2 on failure).
4. **"When NOT to use a team" anti-pattern list** — shared single artifact → single-writer or one session; hard-realtime work bottlenecked on lead approval; hard gate depending on self-reported completion; "looks parallel but state is coupled" (Pattern 5).
5. **Task-completion-lag operational guidance** — a lead-side watchdog convention + defensive `TeammateIdle` hooks to catch stalls before they block dependents.
6. **The per-teammate permission-mode-change mechanism**, once found, added to the display-controls and permissions sections.
7. **Explicit model-precedence rule** between `/config` default and subagent-definition `model`.

**Nice-to-have**
8. One full **worked example** end-to-end: real spawn prompt, resulting task-list snapshot, real hook script, synthesis step. (This gap is exactly what let Patterns 4/5's shared-file issues go unexamined.)
9. **Version-claim verification** — a "last verified against vX" stamp per section, since behavior is pinned to v2.1.178/179/181/186 and the feature is fast-moving.
10. **MCP/skills interaction caveats** — e.g., if a project MCP server needs interactive OAuth, which teammate's transcript shows the prompt, and does it stall behind the 30s idle-hide?
11. **Broadcast-workaround pattern** — a prescribed convention (lead relays cross-cutting messages, or a shared scratch file all teammates check) instead of leaving fan-out to fail silently.
12. **Shared-artifact ownership pattern** — single owner applies all changes; others submit proposed diffs by message. The concrete fix Patterns 4 and 5 need.
13. **Lightweight cost-estimation rubric** — a rough teammates × tasks × tokens/task table to sanity-check cost *before* spawning.

---

## Workspace cleanup notes

- [agent-teams-reference.md](agent-teams-reference.md) is accurate against the source but **carries the ⚠️ gaps above** — it states facts (`cleanupPeriodDays`, per-teammate mode change, hook payloads) without the actionable detail. Fold the must-fix items in once the underlying facts are verified against live docs.
- [CLAUDE.md](../CLAUDE.md) correctly points to the reference guide; no changes needed.
- This repo already has agent teams **enabled** via `.claude/settings.local.json`.
- `fuel-farm-build-sheet.md` was excluded from this task per instructions; it is unrelated to agent teams and left as-is.
