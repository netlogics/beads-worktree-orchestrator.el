;;; beads-worktree-orchestrator.el --- Emacs glue for the beads-worktree-orchestrator skill -*- lexical-binding: t; -*-

;; Author: Philip Smerud
;; Version: see VERSION file
;; Package-Requires: ((emacs "27.1") (ai-code "0"))
;; Keywords: tools, ai

;;; Commentary:

;; Bundles the beads-worktree-orchestrator Claude Code skill together with
;; the Emacs-side glue it depends on, so neither has to be copy-pasted by
;; hand into a user's config or `.claude/skills/`:
;;
;; - `my/spawn-agent-worktree' (alias of
;;   `beads-worktree-orchestrator-spawn-agent-worktree') — called by the
;;   skill via `emacsclient --eval' to create a git worktree for a branch
;;   and start an ai-code CLI session in it (via `ai-code-cli-start' for
;;   most backends — or, for `claude-code-ide', directly via `claude-code-ide'
;;   to work around a bug in its "already running" check — so it follows
;;   whatever backend `ai-code-set-backend' currently selects).
;;   Worktrees are created under `ai-code-git-worktree-root', the same
;;   location `ai-code-git-worktree-branch' uses for worktrees created by
;;   hand — intentionally, so there is one worktree root, not two
;;   conventions drifting apart. See the function's docstring for details.
;;
;; - `beads-worktree-orchestrator-install-skill' — installs or upgrades the
;;   bundled skill into `beads-worktree-orchestrator-skills-dir'.  Each
;;   payload file is synced with a three-way comparison against a snapshot
;;   of what was last installed, so a user's local edits are never silently
;;   clobbered:
;;
;;     unedited, upstream unchanged -> no-op
;;     unedited, upstream changed   -> upgrade silently
;;     edited,   upstream unchanged -> no-op (nothing to reconcile)
;;     edited,   upstream changed   -> CONFLICT: stop, show a diff, and
;;                                     either point at git history (if the
;;                                     installed file is git-tracked) or
;;                                     write a .bak backup (if not)

;;; Code:

(require 'cl-lib)

(defgroup beads-worktree-orchestrator nil
  "Multi-agent orchestration via Beads, git worktrees, and claude-code-ide."
  :group 'tools)

(defcustom beads-worktree-orchestrator-skills-dir
  (expand-file-name "~/.claude/skills/")
  "Directory containing installed Claude Code skills."
  :type 'directory
  :group 'beads-worktree-orchestrator)

(defconst beads-worktree-orchestrator--package-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory this package (and its bundled skill payload) lives in.")

(defconst beads-worktree-orchestrator--skill-files
  '("SKILL.md" "README.md" "assets/orchestrator.default.yml")
  "Files making up the installable skill payload, relative to the package dir.")

(defconst beads-worktree-orchestrator-unsafe-worker-permissions-envvar
  "BEADS_WORKTREE_ORCHESTRATOR_UNSAFE_WORKER_PERMISSIONS"
  "Environment variable that opts spawned workers into bypassed permissions.

See `beads-worktree-orchestrator-worker-permission-mode' for what this
controls and why it's an env var rather than a function argument.")

(defcustom beads-worktree-orchestrator-worker-permission-mode
  (when (getenv beads-worktree-orchestrator-unsafe-worker-permissions-envvar)
    "bypassPermissions")
  "Permission mode passed to spawned worker sessions via `--permission-mode'.

Secure by default: nil, meaning spawned workers get normal (blocking)
permission prompting, same as any manual session — which in practice
means they will stall on their first Bash command or file edit, since
nobody is watching an unattended worker's session to answer \"Do you want
to proceed? 1. Yes...\". To opt in to workers running unattended, set the
environment variable named by
`beads-worktree-orchestrator-unsafe-worker-permissions-envvar'
\(BEADS_WORKTREE_ORCHESTRATOR_UNSAFE_WORKER_PERMISSIONS\) to a non-empty
value *before* this package is loaded (e.g. before starting/restarting
the Emacs daemon, or before `(require \\='beads-worktree-orchestrator)'
runs) — this variable's default is computed once, at load time, from
that environment.

This is deliberately NOT exposed as a function argument anywhere in this
package. `beads-worktree-orchestrator-spawn-agent-worktree' is invoked via
`emacsclient --eval', a channel that can be driven by an LLM agent acting
on untrusted content (a bd issue description, a prompt-injected file, a
compromised sub-agent). If bypassing permissions were a parameter of that
call, anything that can influence what gets passed into that `--eval'
form could silently flip a spawned worker into unattended/no-approval
mode. Requiring a real environment variable, set through a channel this
package's own arguments cannot reach, means the *only* way to enable this
is a deliberate action outside the automated path altogether.

Once enabled, this is applied only to sessions this package spawns, via a
dynamic `let' around the session-start call — not a global `setq' — so
manually-started `ai-code-menu' sessions still prompt normally regardless
of this setting. And it only takes effect when the active `ai-code'
backend is `claude-code-ide' (the only backend this package currently
knows how to pre-approve for); see
`beads-worktree-orchestrator--start-worker-session'.

You can also set this directly (via `setq' or Customize) instead of/in
addition to the environment variable, for persistent local configuration
— it carries the exact same security caveat either way: only set it if
you accept that spawned workers will run with no approval gate at all,
bounded only by their own isolated git worktree."
  :type '(choice (const :tag "Bypass all permission checks (unsafe)" "bypassPermissions")
                  (const :tag "Normal prompting (workers will stall on prompts)" nil)
                  (string :tag "Other claude --permission-mode value"))
  :group 'beads-worktree-orchestrator)

(cl-defstruct beads-worktree-orchestrator--sync-result
  relpath action detail)

;;; ---------------------------------------------------------------------
;;; Agent spawning
;;; ---------------------------------------------------------------------

(defun beads-worktree-orchestrator--branch-exists-p (repo-root branch)
  (zerop (call-process "git" nil nil nil "-C" repo-root
                        "show-ref" "--verify" "--quiet"
                        (concat "refs/heads/" branch))))

(declare-function claude-code-ide "claude-code-ide" (&optional arg))
(declare-function claude-code-ide-send-prompt "claude-code-ide" (&optional prompt))
(declare-function claude-code-ide-mcp--get-session-for-project "claude-code-ide-mcp" (project-dir))
(declare-function claude-code-ide-mcp-session-client "claude-code-ide-mcp" (session))
(declare-function ai-code--effective-backend "ai-code-backends" ())
(declare-function ai-code--activate-effective-backend "ai-code-backends" ())
(declare-function ai-code--remember-current-backend-for-repo "ai-code-backends" ())

(defun beads-worktree-orchestrator--claude-code-ide-active-p ()
  "Non-nil if the effective `ai-code' backend is `claude-code-ide'.

Assumes `ai-code--activate-effective-backend' has already been run for the
current context, same as `ai-code-cli-start' requires before checking what
backend is active."
  (and (fboundp 'ai-code--effective-backend)
       (eq (ai-code--effective-backend) 'claude-code-ide)))

(defun beads-worktree-orchestrator--start-worker-session ()
  "Start an ai-code session in `default-directory' for a spawned worker.

Pre-approves permissions per `beads-worktree-orchestrator-worker-permission-mode'
when the active `ai-code' backend is `claude-code-ide' — the only backend
this currently knows how to pre-approve for, since `claude-code-ide-cli-extra-flags'
is specific to that package. Other backends fall back to whatever their
own default (normal, blocking) prompting behavior is.

When the effective backend is `claude-code-ide', this calls `claude-code-ide'
directly instead of going through `ai-code-cli-start'. `ai-code-cli-start'
dispatches to that backend's `:start' function, `claude-code-ide--start-if-no-session',
whose \"is a session already running\" check is keyed off MCP session context
tied to Emacs's currently focused buffer rather than `default-directory' —
so it can wrongly report \"already running\" for a worktree that has never
had a session started in it, if some unrelated buffer happens to look
active. Calling `claude-code-ide' directly bypasses that buggy check, while
still replicating `ai-code-cli-start''s other bookkeeping (activating the
effective backend beforehand, remembering it for the repo afterward) so
that side of the behavior stays the same regardless of which path is
taken. Other backends are unaffected by this bug and keep using
`ai-code-cli-start' as the generic path."
  (when (fboundp 'ai-code--activate-effective-backend)
    (ai-code--activate-effective-backend))
  (let ((claude-code-ide-p (beads-worktree-orchestrator--claude-code-ide-active-p)))
    (prog1
        (if (and beads-worktree-orchestrator-worker-permission-mode
                 (boundp 'claude-code-ide-cli-extra-flags))
            (let ((claude-code-ide-cli-extra-flags
                   (string-trim (concat claude-code-ide-cli-extra-flags
                                         " --permission-mode "
                                         beads-worktree-orchestrator-worker-permission-mode))))
              (if claude-code-ide-p
                  (claude-code-ide)
                (ai-code-cli-start)))
          (if claude-code-ide-p
              (claude-code-ide)
            (ai-code-cli-start)))
      (when (fboundp 'ai-code--remember-current-backend-for-repo)
        (ai-code--remember-current-backend-for-repo)))))

(defun beads-worktree-orchestrator--worktree-path (repo-root branch)
  "Path for a worktree of BRANCH off REPO-ROOT, under `ai-code-git-worktree-root'.

Deliberately mirrors the private `ai-code--git-worktree-repo-dir' /
`ai-code-git-worktree-branch' layout (ROOT/REPO-NAME/BRANCH) instead of
reimplementing an independent convention — see the spawn function's
docstring for why this integration is intentional."
  (expand-file-name branch
                     (expand-file-name (file-name-nondirectory (directory-file-name repo-root))
                                        ai-code-git-worktree-root)))

;;;###autoload
(defun beads-worktree-orchestrator-spawn-agent-worktree (repo-root branch &optional start-point)
  "Create a git worktree for BRANCH off REPO-ROOT and start an ai-code session in it.

Called by the beads-worktree-orchestrator skill via `emacsclient --eval'.
Unlike earlier versions of this function, it creates the worktree itself
rather than expecting the caller to have already run `git worktree add'
— see \"Worktree location\" below for why, and why the location it picks
is not arbitrary.

If BRANCH already exists, the existing branch is checked out into the
new worktree instead of erroring (mirroring `ai-code-git-worktree-branch').
START-POINT, if given, is the ref the new branch is created from; it is
ignored when BRANCH already exists.  Returns a string describing what
happened (worktree path, branch, and the session-start result), so a
caller driving this via `emacsclient --eval' — e.g. the orchestrator
skill — sees output equivalent to what a separate `git worktree add'
shell command plus a session-start call would have shown, in one line.

Once the worktree exists, this starts the session via
`beads-worktree-orchestrator--start-worker-session', which pre-approves
permissions per `beads-worktree-orchestrator-worker-permission-mode' so
an unattended worker doesn't stall on its first interactive prompt.

Worktree location: worktrees are created under `ai-code-git-worktree-root'
using the exact same ROOT/REPO-NAME/BRANCH layout `ai-code-git-worktree-branch'
uses for worktrees created by hand via `ai-code-menu'.  This is
intentional, not a coincidence of shared defaults: it means there is one
worktree root to look at, clean up, and reason about, regardless of
whether a given worktree was spawned by this orchestrator or created
manually — instead of two conventions (\"sibling of repo root\" vs.
\"centralized under ai-code-git-worktree-root\") silently diverging over
time and leaving worktrees scattered in two different places depending
on how they were created."
  (unless (require 'ai-code-backends nil t)
    (user-error "ai-code-interface.el is not available"))
  (require 'ai-code-git)
  (let* ((repo-root (file-name-as-directory (expand-file-name repo-root)))
         (branch-exists (beads-worktree-orchestrator--branch-exists-p repo-root branch))
         (worktree-path (beads-worktree-orchestrator--worktree-path repo-root branch)))
    (when (file-directory-p worktree-path)
      (user-error "Worktree already exists: %s" worktree-path))
    (make-directory (file-name-directory (directory-file-name worktree-path)) t)
    (with-temp-buffer
      (let ((exit (apply #'call-process "git" nil t nil "-C" repo-root "worktree" "add"
                          (if branch-exists
                              (list worktree-path branch)
                            (append (list "-b" branch worktree-path)
                                    (when start-point (list start-point)))))))
        (unless (zerop exit)
          (user-error "git worktree add failed: %s" (string-trim (buffer-string))))))
    (let ((default-directory (file-name-as-directory worktree-path)))
      (format "Created worktree %s (branch %s%s); %s"
              worktree-path branch
              (if branch-exists ", reusing existing branch" "")
              (beads-worktree-orchestrator--start-worker-session)))))

;;;###autoload
(defalias 'my/spawn-agent-worktree #'beads-worktree-orchestrator-spawn-agent-worktree
  "Compatibility alias — the skill's SKILL.md hardcodes this exact name.")

(defun beads-worktree-orchestrator--head-sha (repo-root branch)
  "Return the commit sha BRANCH currently points to in REPO-ROOT."
  (with-temp-buffer
    (let ((exit (call-process "git" nil t nil "-C" repo-root "rev-parse" branch)))
      (unless (zerop exit)
        (user-error "git rev-parse %s failed: %s" branch (string-trim (buffer-string)))))
    (string-trim (buffer-string))))

;;;###autoload
(defun beads-worktree-orchestrator-spawn-reviewer (repo-root branch)
  "Create a detached-HEAD worktree reviewing BRANCH and start a session in it.

Called by the beads-worktree-orchestrator skill when spawning a reviewer
for an implementer's already-closed bead. A reviewer needs read access to
the implementer's branch as it stood at review time, but git refuses to
check out the same branch into two worktrees at once (\"already checked
out\" — `git worktree add' errors if BRANCH is checked out anywhere else,
including the implementer's own worktree that is likely still alive).
There is no supported way to get a second, independent worktree onto the
same branch ref.

The workaround, discovered live while orchestrating a real review pass,
is to resolve BRANCH's current commit and check that sha out **detached**
in a new worktree instead of checking out the branch itself. A detached
HEAD is just a checkout of a specific commit with no branch attached, so
git's one-worktree-per-branch restriction never applies — any number of
detached worktrees can point at the same commit simultaneously. The
reviewer gets a real, independent working tree with exactly the
implementer's reviewed code, and can run its own commands (tests,
linters) in it without disturbing or being disturbed by the implementer's
worktree.

This intentionally does not take a START-POINT/create-branch path the way
`beads-worktree-orchestrator-spawn-agent-worktree' does — a reviewer never
commits, so there is no branch for it to advance; leaving it detached
also makes `git worktree list' visually distinguish review worktrees
(no branch column) from implementer ones.

The worktree is created under `ai-code-git-worktree-root', using the same
ROOT/REPO-NAME/<name> convention as
`beads-worktree-orchestrator--worktree-path', but named
\"review-BRANCH-WITH-SLASHES-REPLACED-BY-DASHES\" rather than BRANCH
itself, so it cannot collide with the implementer's own worktree path
and is identifiable at a glance in `git worktree list'. BRANCH is
sanitized (every \"/\" replaced with \"-\") before being folded into
this name: real branches spawned by
`beads-worktree-orchestrator-spawn-agent-worktree' always look like
\"agent/impl-bd-<id>\", and passing that through unsanitized would make
`expand-file-name' treat \"review-agent/impl-bd-<id>\" as a *nested*
path (a \"review-agent\" directory containing \"impl-bd-<id>\") rather
than a flat sibling directory — nesting it one level inside the
implementer's own path and making the two worktrees' last path segment
identical, which is exactly what `ai-code' derives session buffer names
from.

Returns a string describing what happened (worktree path, reviewed
branch and sha, and the session-start result), mirroring
`beads-worktree-orchestrator-spawn-agent-worktree'."
  (unless (require 'ai-code-backends nil t)
    (user-error "ai-code-interface.el is not available"))
  (require 'ai-code-git)
  (let* ((repo-root (file-name-as-directory (expand-file-name repo-root)))
         (sha (beads-worktree-orchestrator--head-sha repo-root branch))
         (review-name (concat "review-" (replace-regexp-in-string "/" "-" branch)))
         (worktree-path (beads-worktree-orchestrator--worktree-path repo-root review-name)))
    (when (file-directory-p worktree-path)
      (user-error "Worktree already exists: %s" worktree-path))
    (make-directory (file-name-directory (directory-file-name worktree-path)) t)
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil "-C" repo-root "worktree" "add"
                                 "--detach" worktree-path sha)))
        (unless (zerop exit)
          (user-error "git worktree add --detach failed: %s" (string-trim (buffer-string))))))
    (let ((default-directory (file-name-as-directory worktree-path)))
      (format "Created detached-HEAD review worktree %s (reviewing %s at %s); %s"
              worktree-path branch sha
              (beads-worktree-orchestrator--start-worker-session)))))

;;; ---------------------------------------------------------------------
;;; Spawn + send prompt (race-condition-safe)
;;; ---------------------------------------------------------------------

(defcustom beads-worktree-orchestrator-session-ready-timeout 30
  "Seconds to wait for a spawned Claude Code session to become ready.
Readiness is signalled by the MCP WebSocket connecting (the `client'
field on the session struct becoming non-nil), which is the last step
of Claude Code startup — it won't accept typed input until this happens.
Increase this on slow machines or when startup consistently times out."
  :type 'number
  :group 'beads-worktree-orchestrator)

(defcustom beads-worktree-orchestrator-post-ready-delay 0.5
  "Extra seconds to wait after MCP connects before sending the opening prompt.
Even after the WebSocket connects, Claude Code may still be rendering its
initial UI (the `>' prompt line). This small pause prevents the typed text
from landing before that rendering completes."
  :type 'number
  :group 'beads-worktree-orchestrator)

(defun beads-worktree-orchestrator--wait-for-mcp-ready (worktree-path)
  "Block until the Claude Code session in WORKTREE-PATH has a live MCP connection.
Polls every 0.5 s up to `beads-worktree-orchestrator-session-ready-timeout'
seconds.  Returns t if the session became ready, nil if it timed out.

Readiness means `claude-code-ide-mcp-session-client' is non-nil for the
session keyed by WORKTREE-PATH — that field is set when the Claude process
opens its MCP WebSocket back to Emacs, which is the last step of startup
and the point at which the terminal is ready to accept typed input."
  (unless (fboundp 'claude-code-ide-mcp--get-session-for-project)
    (user-error "claude-code-ide-mcp is not available"))
  (let ((deadline (+ (float-time) beads-worktree-orchestrator-session-ready-timeout))
        (dir (file-name-as-directory (expand-file-name worktree-path)))
        (ready nil))
    (while (and (not ready) (< (float-time) deadline))
      (when-let ((session (claude-code-ide-mcp--get-session-for-project dir)))
        (when (claude-code-ide-mcp-session-client session)
          (setq ready t)))
      (unless ready (sleep-for 0.5)))
    ready))

;;;###autoload
(defun beads-worktree-orchestrator-spawn-and-send-prompt (repo-root branch prompt &optional start-point)
  "Create worktree for BRANCH, start a session, wait until ready, then send PROMPT.

Combines `beads-worktree-orchestrator-spawn-agent-worktree' with a
readiness wait and `claude-code-ide-send-prompt'.  The wait polls for
the MCP WebSocket to connect (see `beads-worktree-orchestrator--wait-for-mcp-ready'),
which is the signal that Claude Code has finished starting and its terminal
is ready to accept typed input.  Without this wait the prompt text is
sometimes entered but never submitted because send-return arrives before
Claude's input loop is running.

START-POINT, if given, is the ref the new branch is created from.
Returns a string describing the outcome (spawn result + prompt delivery status)."
  (let* ((spawn-result
          (beads-worktree-orchestrator-spawn-agent-worktree repo-root branch start-point))
         (worktree-path
          (beads-worktree-orchestrator--worktree-path
           (file-name-as-directory (expand-file-name repo-root)) branch))
         (default-directory (file-name-as-directory worktree-path)))
    (if (beads-worktree-orchestrator--wait-for-mcp-ready worktree-path)
        (progn
          (when (> beads-worktree-orchestrator-post-ready-delay 0)
            (sleep-for beads-worktree-orchestrator-post-ready-delay))
          (claude-code-ide-send-prompt prompt)
          (format "%s; sent opening prompt (%d chars)" spawn-result (length prompt)))
      (format "%s; WARNING: MCP did not connect within %ss — prompt not sent, worker needs manual kick"
              spawn-result beads-worktree-orchestrator-session-ready-timeout))))

;;;###autoload
(defun beads-worktree-orchestrator-spawn-reviewer-and-send-prompt (repo-root branch prompt)
  "Create detached-HEAD review worktree for BRANCH, wait until ready, then send PROMPT.

Like `beads-worktree-orchestrator-spawn-and-send-prompt' but uses
`beads-worktree-orchestrator-spawn-reviewer' to create a detached-HEAD
worktree (needed because the implementer's branch is already checked out
in a live worktree and git forbids two worktrees on the same branch).

Returns a string describing the outcome."
  (let* ((repo-root (file-name-as-directory (expand-file-name repo-root)))
         (review-name (concat "review-" (replace-regexp-in-string "/" "-" branch)))
         (worktree-path (beads-worktree-orchestrator--worktree-path repo-root review-name))
         (spawn-result
          (beads-worktree-orchestrator-spawn-reviewer repo-root branch))
         (default-directory (file-name-as-directory worktree-path)))
    (if (beads-worktree-orchestrator--wait-for-mcp-ready worktree-path)
        (progn
          (when (> beads-worktree-orchestrator-post-ready-delay 0)
            (sleep-for beads-worktree-orchestrator-post-ready-delay))
          (claude-code-ide-send-prompt prompt)
          (format "%s; sent opening prompt (%d chars)" spawn-result (length prompt)))
      (format "%s; WARNING: MCP did not connect within %ss — prompt not sent, worker needs manual kick"
              spawn-result beads-worktree-orchestrator-session-ready-timeout))))

;;; ---------------------------------------------------------------------
;;; Install / upgrade state
;;; ---------------------------------------------------------------------

(defun beads-worktree-orchestrator--canonical-version ()
  "Version string of the bundled (canonical) skill."
  (string-trim
   (with-temp-buffer
     (insert-file-contents (expand-file-name "VERSION" beads-worktree-orchestrator--package-dir))
     (buffer-string))))

(defun beads-worktree-orchestrator--installed-dir ()
  (expand-file-name "beads-worktree-orchestrator" beads-worktree-orchestrator-skills-dir))

(defun beads-worktree-orchestrator--state-dir ()
  "Directory mirroring the payload files as they stood at last install.
This is what makes the three-way comparison possible: without a copy of
what was actually installed, there is no way to tell \"user edited this\"
apart from \"upstream changed this\" — only hashing the two live copies
against each other can't distinguish those cases."
  (expand-file-name ".install-state" (beads-worktree-orchestrator--installed-dir)))

(defun beads-worktree-orchestrator--state-file ()
  (expand-file-name ".install-state.el" (beads-worktree-orchestrator--installed-dir)))

(defun beads-worktree-orchestrator--read-state ()
  "Return the install-state plist, or nil if never installed."
  (let ((file (beads-worktree-orchestrator--state-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (read (current-buffer))))))

(defun beads-worktree-orchestrator--write-state (version)
  (let ((file (beads-worktree-orchestrator--state-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 (list :installed-version version
                   :installed-at (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
             (current-buffer)))))

;;; ---------------------------------------------------------------------
;;; File comparison / git awareness
;;; ---------------------------------------------------------------------

(defun beads-worktree-orchestrator--files-equal-p (a b)
  "Non-nil if files A and B both exist and have identical contents."
  (and (file-readable-p a) (file-readable-p b)
       (zerop (call-process "diff" nil nil nil "-q" a b))))

(defun beads-worktree-orchestrator--git-tracked-p (path)
  "Non-nil if PATH is inside a git repo AND tracked by it.
A repo existing somewhere above PATH isn't enough on its own — the file
itself might never have been added (e.g. `.claude/skills/` gitignored,
or copied in from outside version control)."
  (let ((default-directory (file-name-directory path)))
    (and (zerop (call-process "git" nil nil nil "rev-parse" "--is-inside-work-tree"))
         (zerop (call-process "git" nil nil nil "ls-files" "--error-unmatch"
                               (file-name-nondirectory path))))))

(defun beads-worktree-orchestrator--diff (label-a file-a label-b file-b)
  "Unified diff between FILE-A and FILE-B, labeled LABEL-A/LABEL-B."
  (with-temp-buffer
    (call-process "diff" nil t nil "-u"
                  "--label" label-a "--label" label-b
                  file-a file-b)
    (buffer-string)))

;;; ---------------------------------------------------------------------
;;; Per-file sync (the three-way comparison)
;;; ---------------------------------------------------------------------

(defun beads-worktree-orchestrator--snapshot (relpath)
  "Copy the just-installed RELPATH into the state-dir mirror."
  (let ((dest (expand-file-name relpath (beads-worktree-orchestrator--state-dir)))
        (src (expand-file-name relpath (beads-worktree-orchestrator--installed-dir))))
    (make-directory (file-name-directory dest) t)
    (copy-file src dest t)))

(defun beads-worktree-orchestrator--conflict-detail (relpath base canonical installed)
  (let ((diff (beads-worktree-orchestrator--diff "yours" installed "new upstream" canonical)))
    (if (beads-worktree-orchestrator--git-tracked-p installed)
        (concat
         (format "`%s` has local edits AND upstream changed it.\n" relpath)
         "It's git-tracked, so your history is already a safety net — see:\n"
         (format "  git -C %s log -- %s\n"
                 (shell-quote-argument (file-name-directory installed))
                 (file-name-nondirectory relpath))
         (format "  git -C %s diff -- %s\n\n"
                 (shell-quote-argument (file-name-directory installed))
                 (file-name-nondirectory relpath))
         "Diff between your version and the new upstream version:\n" diff)
      (let ((backup (concat installed ".bak")))
        (copy-file installed backup t)
        (concat
         (format "`%s` has local edits AND upstream changed it.\n" relpath)
         (format "Not git-tracked, so your current version was backed up to:\n  %s\n\n" backup)
         "Diff between your version and the new upstream version:\n" diff)))))

(defun beads-worktree-orchestrator--sync-file (relpath)
  "Sync one RELPATH of the skill payload. Returns a `beads-worktree-orchestrator--sync-result'."
  (let* ((canonical (expand-file-name relpath beads-worktree-orchestrator--package-dir))
         (installed (expand-file-name relpath (beads-worktree-orchestrator--installed-dir)))
         (base (expand-file-name relpath (beads-worktree-orchestrator--state-dir))))
    (make-directory (file-name-directory installed) t)
    (cond
     ;; Never installed before.
     ((not (file-readable-p installed))
      (copy-file canonical installed)
      (beads-worktree-orchestrator--snapshot relpath)
      (make-beads-worktree-orchestrator--sync-result :relpath relpath :action 'installed))
     ;; No prior snapshot (predates this mechanism, or was placed by hand) —
     ;; fall back to treating the installed file itself as the base, so a
     ;; byte-identical file upgrades silently and anything else is a conflict
     ;; rather than risking a silent clobber of unknown edits.
     (t
      (let* ((base (if (file-readable-p base) base installed))
             (user-edited (not (beads-worktree-orchestrator--files-equal-p base installed)))
             (upstream-changed (not (beads-worktree-orchestrator--files-equal-p base canonical))))
        (cond
         ((not upstream-changed)
          (make-beads-worktree-orchestrator--sync-result :relpath relpath :action 'unchanged))
         ((not user-edited)
          (copy-file canonical installed t)
          (beads-worktree-orchestrator--snapshot relpath)
          (make-beads-worktree-orchestrator--sync-result :relpath relpath :action 'updated))
         (t
          (make-beads-worktree-orchestrator--sync-result
           :relpath relpath :action 'conflict
           :detail (beads-worktree-orchestrator--conflict-detail relpath base canonical installed)))))))))

;;; ---------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------

;;;###autoload
(defun beads-worktree-orchestrator-install-skill ()
  "Install or upgrade the bundled beads-worktree-orchestrator skill.

Copies into `beads-worktree-orchestrator-skills-dir', syncing each payload
file independently with a three-way comparison (see commentary at the top
of this file). Reports results in *beads-worktree-orchestrator-install*."
  (interactive)
  (let* ((version (beads-worktree-orchestrator--canonical-version))
         (results (mapcar #'beads-worktree-orchestrator--sync-file
                           beads-worktree-orchestrator--skill-files))
         (conflicts (cl-remove-if-not
                     (lambda (r) (eq (beads-worktree-orchestrator--sync-result-action r) 'conflict))
                     results)))
    (beads-worktree-orchestrator--write-state version)
    (with-current-buffer (get-buffer-create "*beads-worktree-orchestrator-install*")
      (erase-buffer)
      (insert (format "beads-worktree-orchestrator skill -> %s\n\n" version))
      (dolist (r results)
        (insert (format "  %-40s %s\n"
                         (beads-worktree-orchestrator--sync-result-relpath r)
                         (beads-worktree-orchestrator--sync-result-action r))))
      (when conflicts
        (insert "\n--- Conflicts needing your attention ---\n\n")
        (dolist (r conflicts)
          (insert (beads-worktree-orchestrator--sync-result-detail r))
          (insert "\n")))
      (goto-char (point-min))
      (display-buffer (current-buffer)))
    (if conflicts
        (message "beads-worktree-orchestrator: installed with %d conflict(s) — see *beads-worktree-orchestrator-install*"
                  (length conflicts))
      (message "beads-worktree-orchestrator: skill up to date (%s)" version))))

(provide 'beads-worktree-orchestrator)

;;; beads-worktree-orchestrator.el ends here
