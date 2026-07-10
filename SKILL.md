 ---
name: beads-worktree-orchestrator
description: Acts as the single orchestrator for multi-agent coding workflows that use Beads (bd) as the shared task queue, git worktrees for per-agent isolation, MCP Agent Mail for agent-to-agent coordination, and Emacs (ai-code-interface.el / claude-code-ide.el) vterm sessions as the workers. Use this skill whenever the user wants to run several AI coding agents in parallel on one repo, distribute Beads issues across worktrees, assign roles like implementer/reviewer/tester to different agents, check on or clean up parallel agent sessions, or otherwise coordinate a fleet of Claude Code / ai-code sessions instead of running one agent at a time. Trigger this even if the user just says "orchestrate the beads," "spin up a review agent too," or "spawn workers for ready tasks" without spelling out worktrees, mail, or Emacs explicitly.
---

# Beads + Worktree Orchestrator

You are acting as the **single orchestrator**: a coordinating agent that assigns ready work to fresh, isolated worker agents (with distinct roles) and tracks them to completion. You do not write the feature code yourself — you manage the fleet.

## Prerequisites (verify before doing anything)

1. `bd --version` succeeds and `.beads/` exists in the repo root (`bd init` if not).
2. The repo is a git repo with a clean-enough working tree.
3. An Emacs daemon is reachable: `emacsclient --eval '1'` returns `1`.
4. `emacsclient --eval "(fboundp 'my/spawn-agent-worktree)"` returns `t`. If not, stop and ask what the user's spawn function is called — don't guess and eval something destructive.
5. MCP Agent Mail is reachable (`am setup status` or the Python CLI's health check, depending on which build the user installed — Go/`am`, Rust, or the original Python FastMCP server). If it's not installed, tell the user to run the one-line installer:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/mcp_agent_mail/main/scripts/install.sh | bash -s -- --yes
   ```
   and confirm the server is configured in their agent's MCP settings before proceeding. Mail is required for the roles below to coordinate with each other; if the user wants to skip it for this run, fall back to bd-only coordination as described in the earlier version of this workflow.

## Configuration: agent count & roles

Look for `.beads/orchestrator.yml` in the repo root — this is per-project config, not part of this skill, so it lives with the rest of the project's Beads state rather than inside the skill package.

- **If it exists**, read it and use its values. Never overwrite a user's existing config.
- **If it doesn't exist**, copy the skill's bundled default into place before proceeding:
  ```bash
  cp assets/orchestrator.default.yml .beads/orchestrator.yml
  ```
  (resolve `assets/orchestrator.default.yml` relative to wherever this skill is installed, e.g. `.claude/skills/beads-worktree-orchestrator/assets/`). Tell the user you seeded it and where, so they know to edit it going forward instead of asking you each time.

The default template ships with: 3 implementer agents, reviewer and integrator disabled (`count: 0`), `max_parallel_agents: 3`. This is exactly the behavior from before mail/roles existed. Turning on `reviewer` or `integrator` is opt-in because each added role increases coordination overhead (more mail traffic, more agents to babysit).

If the user asks to customize inline instead of via the file ("give me 4 implementers and 1 reviewer"), treat their message as an override for this run only — don't silently write `.beads/orchestrator.yml` for them unless they ask you to persist it.

**Role definitions**:
- **implementer** — claims a ready bead, works in its own worktree, writes code + tests, closes the bead when done. This is the only role in the default config.
- **reviewer** — does not claim beads directly. Spawned to review an implementer's diff before merge; posts findings via mail to the implementer's thread rather than editing code itself. Needs read access to the implementer's worktree, not its own.
- **integrator** — does not implement features. Periodically checks for closed beads with unmerged branches, runs the full test suite after merging into a scratch branch, and reports conflicts back to the relevant implementer via mail instead of resolving silently.

## The orchestration loop

### 1. Discover ready work
```bash
bd ready --json
```
Filter out anything already `in_progress` or claimed.

### 2. Check capacity per role
```bash
git worktree list
```
Count active worktrees by role prefix (see naming below). Respect each role's `count` and the overall `max_parallel_agents` cap. Never exceed either.

### 3. Spawn implementer(s)
For each selected bead `bd-<id>`:
```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
emacsclient --eval "(my/spawn-agent-worktree \"$REPO_ROOT\" \"agent/impl-bd-<id>\")"
bd update bd-<id> --status in_progress --assignee agent-impl-bd-<id>
```
`my/spawn-agent-worktree` creates the worktree itself — it takes the repo's absolute path (use an absolute path since `emacsclient --eval` runs in the Emacs server's context, not the shell's cwd) and the branch name, and returns a string describing what it did, so this one line covers what used to be a separate `git worktree add` plus a session-start call. It does **not** create the worktree as a sibling of the repo — it uses `ai-code-git-worktree-root/<repo-name>/<branch>`, the same location `ai-code-git-worktree-branch` (the manual, interactive worktree command in `ai-code-menu`) uses. That's intentional: worktrees spawned by this skill and worktrees a human creates by hand end up in the same place, so there's one worktree root to look at and clean up, not two conventions to keep in sync. Run `git worktree list` (or check the returned path directly) rather than assuming `../wt-impl-bd-<id>` if you need to find it.

**Permission prompts.** By default the spawned worker will stall on its first interactive permission prompt (Bash command, file edit) since nobody's watching its session — you'll need to send a keystroke into its vterm buffer to unblock it, every time, for every worker. If the user has opted in to unattended workers (`BEADS_WORKTREE_ORCHESTRATOR_UNSAFE_WORKER_PERMISSIONS` set before the Emacs daemon started — see the package's README), this doesn't happen. If you notice a worker has had no bd/git/mail activity for a while, check its session buffer for a stuck prompt before assuming it's actually idle or stalled on the task itself.
Register the agent's identity in Agent Mail (name it `impl-bd-<id>` so mail and bd IDs line up) and seed its first message/thread with the bead's `thread_id` set to `bd-<id>`, per the shared-identifier convention (`[bd-<id>]` subject prefix). This is what lets you and other agents later pull "everything related to this bead" from either system.

Seed the worker's opening prompt with: the bead description (`bd show bd-<id> --json`), an instruction to run tests before closing, an instruction to close the bead itself (`bd close bd-<id> --reason "..."`), and — new — an instruction to **check its Agent Mail inbox periodically and check its thread before touching files** another agent might also be touching. If it needs to touch files outside its own worktree (shared config, generated schemas, etc.) it should call the file-reservation tool with a TTL before editing, and mail the bead's thread if it's blocked on something another agent owns.

### 4. Spawn reviewer/integrator (only if `count > 0`)
- **Reviewer**: spawn only after an implementer closes a bead (`bd update ... --status closed` observed). Give it read-only access to the worktree/branch, not a new worktree of its own — it doesn't need file isolation since it isn't editing. Its output is a mail message to the implementer's thread (`[bd-<id>] review notes`), not a code change.
- **Integrator**: spawn on its own cadence per `spawn_when` — check `git branch --merged` counts, or just re-check each time you're invoked. It merges into a scratch integration branch, runs tests, and mails the relevant implementer thread(s) if something breaks — it does not force-push over anyone's branch.

### 5. When to use mail vs. bd (guidance for the workers, and for you)
Tell every spawned worker this rule of thumb: **bd is for what's true and needs to persist — task status, dependencies, what's done. Mail is for what's being negotiated right now — live conflicts, splitting ambiguous work, "heads up I'm touching X," questions that don't need a permanent record.** If in doubt: if the next agent who wakes up cold should see it, it belongs in bd; if it's just this negotiation, it belongs in mail.

### 6. Check on workers (on request, or when re-invoked)
```bash
bd list --status in_progress --json
git worktree list   # each worker's path is under ai-code-git-worktree-root/<repo-name>/agent/impl-bd-<id>
git -C <worktree-path> status --short
git -C <worktree-path> log -1 --format=%cr
```
Also check each active agent's Agent Mail inbox for unread messages flagged urgent or unresolved for a long time — that's often a sign two agents are blocked on each other and need you to intervene, which mail alone won't force to your attention since it's asynchronous.

If a worker shows no bd activity, no commits, and no mail activity for an unusually long time, **report this to the user** — don't auto-kill it.

### 7. Clean up completed work
When `bd show bd-<id>` shows `status: closed` and (if a reviewer is enabled) review is resolved:
1. Confirm the branch is merged, or hand off to the integrator role if enabled.
2. `git worktree remove <worktree-path>` (find it via `git worktree list` if not already known)
3. `git branch -d agent/impl-bd-<id>`
4. Loop back to step 1 for the freed implementer slot.

## Safety rules (non-negotiable)

- Never `git worktree remove --force` or delete a branch with unmerged commits without explicit user confirmation.
- Never claim a bead that already has a non-empty `--assignee`.
- Never exceed `max_parallel_agents` or any individual role's `count`, even if there's more ready work — report queue depth and ask before raising the cap.
- Reviewer and integrator agents never edit implementer code directly — they only report via mail. This keeps blame/attribution clean and avoids two agents fighting over the same files.
- If `emacsclient` or the Agent Mail server calls fail, stop and surface the exact error — don't silently fall back to running agents headlessly or coordinating without mail unless the user explicitly asks for that degraded mode.

## Reporting back to the user

Summarize each pass in this shape:
- Spawned: `<n>` agents (`<role>: <bead-ids>`)
- Still running: `<bead-ids>` with last bd/git/mail activity age
- Unread/urgent mail flags: any threads that look stuck
- Closed & cleaned up: `<bead-ids>`
- Blocked / needs a human: stalled agents, merge conflicts, ambiguous deps, or config the user hasn't set (e.g. "reviewer role is enabled but count is 0 — did you mean to set it to 1?")
