;;; beads-worktree-orchestrator.el --- Emacs glue for the beads-worktree-orchestrator skill -*- lexical-binding: t; -*-

;; Author: Philip Smerud
;; Version: see VERSION file
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, ai

;;; Commentary:

;; Bundles the beads-worktree-orchestrator Claude Code skill together with
;; the Emacs-side glue it depends on, so neither has to be copy-pasted by
;; hand into a user's config or `.claude/skills/`:
;;
;; - `my/spawn-agent-worktree' (alias of
;;   `beads-worktree-orchestrator-spawn-agent-worktree') — called by the
;;   skill via `emacsclient --eval' to start a claude-code-ide session in a
;;   freshly created git worktree.
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

(cl-defstruct beads-worktree-orchestrator--sync-result
  relpath action detail)

;;; ---------------------------------------------------------------------
;;; Agent spawning
;;; ---------------------------------------------------------------------

;;;###autoload
(defun beads-worktree-orchestrator-spawn-agent-worktree (worktree-path)
  "Start a claude-code-ide session rooted at WORKTREE-PATH.

Called by the beads-worktree-orchestrator skill via `emacsclient --eval'
once it has already run `git worktree add' for WORKTREE-PATH; this
function only needs to launch (or reattach to) a session scoped to that
directory.  claude-code-ide's default buffer naming derives the session's
buffer name from the directory's basename, so naming worktrees
descriptively (e.g. \"wt-impl-bd-42\") is what keeps
`claude-code-ide-list-sessions' legible with several agents running."
  (unless (require 'claude-code-ide nil t)
    (user-error "claude-code-ide is not available"))
  (let ((default-directory (file-name-as-directory (expand-file-name worktree-path))))
    (unless (file-directory-p default-directory)
      (user-error "Worktree does not exist: %s" default-directory))
    (funcall (intern "claude-code-ide"))))

;;;###autoload
(defalias 'my/spawn-agent-worktree #'beads-worktree-orchestrator-spawn-agent-worktree
  "Compatibility alias — the skill's SKILL.md hardcodes this exact name.")

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
