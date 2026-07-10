# Beads + Worktree Orchestrator (Claude Code skill)

Turns Claude into a **single orchestrator** that runs several AI coding agents on your repo at once — each in its own isolated git worktree, coordinated through [Beads](https://github.com/steveyegge/beads) as the task queue and [MCP Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) for agent-to-agent messaging, driven from Emacs vterm sessions.

## What it actually does

Instead of you manually creating a worktree, starting an agent, and remembering what it's working on, this skill:

1. Reads `bd ready` to find unblocked tasks.
2. Spawns agents (up to a configurable limit) into their own git worktrees, so they can never step on each other's files.
3. Assigns each agent a role — `implementer` by default, optionally `reviewer` and `integrator`.
4. Lets agents coordinate with each other over Agent Mail for anything transient (file conflicts, negotiating who does what), while keeping Beads as the durable record of task status.
5. Cleans up worktrees and branches once a task is closed and merged.
6. Reports back to you in plain language — what's running, what's stuck, what needs your attention — rather than raw command output.

**It never writes code itself.** It manages the fleet; the spawned agents do the implementation.

## Prerequisites

You need all of these installed and working *before* this skill will do anything:

| Requirement | Check it works with |
|---|---|
| [Beads](https://github.com/steveyegge/beads) (`bd`) | `bd --version`, and `.beads/` exists in your repo (`bd init` if not) |
| Git | any reasonably recent version; worktrees are a standard feature |
| Emacs with a running daemon | `emacsclient --eval '1'` should print `1` |
| [ai-code-interface.el](https://github.com/tninja/ai-code-interface.el) | provides `ai-code-cli-start`, the backend-agnostic dispatcher the bundled spawn function calls; pick a backend with `ai-code-set-backend` (e.g. `'claude-code-ide`, which additionally requires [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)) |
| Worktree-spawn function in your Emacs config | bundled in this repo as `my/spawn-agent-worktree` (`beads-worktree-orchestrator.el`) — load it in your config; given a repo root and branch name, it creates the worktree under `ai-code-git-worktree-root` (the same location `ai-code-git-worktree-branch` uses for worktrees created by hand, intentionally — one worktree root, not two conventions) and calls `ai-code-cli-start` in it |
| [MCP Agent Mail](https://github.com/Dicklesworthstone/mcp_agent_mail) | installed and configured in your agent's MCP settings; the one-line installer is `curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/mcp_agent_mail/main/scripts/install.sh \| bash -s -- --yes` |

If any of these are missing, the skill will stop and tell you what's missing rather than guessing or silently degrading — except that if Agent Mail specifically isn't set up, you can explicitly ask it to fall back to Beads-only coordination for that run.

## Installing

**Emacs side** — load `beads-worktree-orchestrator.el` from this repo (e.g. via `straight.el`, `elpaca`, or plain `:load-path`) so `my/spawn-agent-worktree` and `beads-worktree-orchestrator-install-skill` are available.

**Skill side** — once the Emacs package above is loaded, run `M-x beads-worktree-orchestrator-install-skill` to install (or upgrade) the bundled skill into `~/.claude/skills/beads-worktree-orchestrator/`. It syncs each file independently and won't silently clobber local edits — see the function's docstring for the conflict-handling details.

Without Emacs, you can still install the skill alone: drop the whole skill folder into your Claude Code skills directory (`unzip beads-worktree-orchestrator.skill -d .claude/skills/`, or place `SKILL.md` + `assets/` at `.claude/skills/beads-worktree-orchestrator/` by hand) — but you'll then need to write your own `my/spawn-agent-worktree` instead of using the bundled one.

## Configuring agent count & roles

The skill reads `.beads/orchestrator.yml` in **your project** (not from the skill folder — this is per-project config, since different repos will want different agent counts). On first run, if that file doesn't exist yet, the skill copies its bundled default (`assets/orchestrator.default.yml`) into place for you and tells you it did so.

Default config (3 implementers, nothing else):

```yaml
max_parallel_agents: 3

roles:
  implementer:
    count: 3
    default: true

  reviewer:
    count: 0        # disabled by default
    spawn_when: "implementer closes a bead"

  integrator:
    count: 0        # disabled by default
    spawn_when: "2+ implementer branches are ready to merge"
```

Edit `.beads/orchestrator.yml` directly to change agent counts or turn on `reviewer`/`integrator`, or just tell Claude inline (e.g. "use 4 implementers and 1 reviewer for this run") for a one-off override without editing the file.

**Role behavior:**
- `implementer` — claims a bead, works in its own worktree, closes the bead when done.
- `reviewer` — read-only access to an implementer's branch; posts findings via Agent Mail rather than editing code.
- `integrator` — periodically merges closed-but-unmerged branches into a scratch branch, runs the test suite, and reports conflicts via Agent Mail rather than resolving them silently.

Reviewers and integrators never touch code directly — this keeps attribution clean and prevents two agents fighting over the same files.

## Safety guarantees

- Never force-deletes a worktree or branch with unmerged commits without asking you first.
- Never exceeds `max_parallel_agents` or any individual role's count, even if more work is ready — it reports queue depth and asks before you raise the cap.
- Never double-claims a bead that already has an assignee.
- If Emacs or Agent Mail calls fail outright, it stops and shows you the exact error rather than working around it silently.
- Stuck agents (no bd/git/mail activity for a long time) are reported to you, not auto-killed.

## What this is *not*

- Not a replacement for Beads' own planning — Beads tracks current, actionable work, not a backlog.
- Not a fully autonomous CI/CD pipeline — merges and cleanup of unmerged work always ask for confirmation.
- Not tied to Claude Code specifically for the *worker* agents — the underlying stack (Beads + worktrees + Agent Mail) works with whatever CLI backend `ai-code-cli-start` is currently pointed at (Claude Code, Codex, Gemini CLI, etc. — see `ai-code-set-backend`). This skill is what's Claude-Code-specific: it's the orchestrator's brain, not the workers'.
