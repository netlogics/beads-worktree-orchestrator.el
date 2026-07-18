;;; beads-worktree-orchestrator-test.el --- ERT tests -*- lexical-binding: t; -*-

;; Run with: emacs --batch -l ert -l beads-worktree-orchestrator.el \
;;             -l tests/beads-worktree-orchestrator-test.el \
;;             -f ert-run-tests-batch-and-exit
;; or simply: tests/run-tests.sh

;;; Commentary:

;; Covers the pure-ish/fixture-friendly helpers in
;; beads-worktree-orchestrator.el using disposable temp directories.
;; Nothing here touches the real ~/.claude/skills or
;; `ai-code-git-worktree-root' — every test binds those (or their
;; equivalents) to freshly created temp dirs and cleans up afterward.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beads-worktree-orchestrator)

(defmacro bwo-test--with-temp-dir (var &rest body)
  "Bind VAR to a fresh temp directory for BODY, deleting it afterward."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "bwo-test-" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,var t))))

(defun bwo-test--write-file (path content)
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content)))

(defun bwo-test--git (dir &rest args)
  (let ((default-directory dir))
    (apply #'call-process "git" nil nil nil args)))

;;; ---------------------------------------------------------------------
;;; --files-equal-p
;;; ---------------------------------------------------------------------

(ert-deftest bwo-test-files-equal-p-identical ()
  (bwo-test--with-temp-dir dir
    (let ((a (expand-file-name "a.txt" dir))
          (b (expand-file-name "b.txt" dir)))
      (bwo-test--write-file a "same content\n")
      (bwo-test--write-file b "same content\n")
      (should (beads-worktree-orchestrator--files-equal-p a b)))))

(ert-deftest bwo-test-files-equal-p-different ()
  (bwo-test--with-temp-dir dir
    (let ((a (expand-file-name "a.txt" dir))
          (b (expand-file-name "b.txt" dir)))
      (bwo-test--write-file a "content one\n")
      (bwo-test--write-file b "content two\n")
      (should-not (beads-worktree-orchestrator--files-equal-p a b)))))

(ert-deftest bwo-test-files-equal-p-missing-file ()
  (bwo-test--with-temp-dir dir
    (let ((a (expand-file-name "a.txt" dir))
          (missing (expand-file-name "nope.txt" dir)))
      (bwo-test--write-file a "content\n")
      (should-not (beads-worktree-orchestrator--files-equal-p a missing))
      (should-not (beads-worktree-orchestrator--files-equal-p missing a)))))

;;; ---------------------------------------------------------------------
;;; --branch-exists-p
;;; ---------------------------------------------------------------------

(ert-deftest bwo-test-branch-exists-p ()
  (bwo-test--with-temp-dir dir
    (bwo-test--git dir "init" "-q" "-b" "main" ".")
    (bwo-test--git dir "config" "user.email" "test@example.com")
    (bwo-test--git dir "config" "user.name" "Test")
    (bwo-test--write-file (expand-file-name "f.txt" dir) "hi\n")
    (bwo-test--git dir "add" "f.txt")
    (bwo-test--git dir "commit" "-q" "-m" "init")
    (bwo-test--git dir "branch" "feature-x")
    (should (beads-worktree-orchestrator--branch-exists-p dir "main"))
    (should (beads-worktree-orchestrator--branch-exists-p dir "feature-x"))
    (should-not (beads-worktree-orchestrator--branch-exists-p dir "does-not-exist"))))

;;; ---------------------------------------------------------------------
;;; --worktree-path
;;; ---------------------------------------------------------------------

(defvar ai-code-git-worktree-root nil
  "Stub for tests; the real definition lives in the external ai-code package.")

(ert-deftest bwo-test-worktree-path ()
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent))
             (expected (expand-file-name "feature-x" (expand-file-name "my-repo" root))))
        (make-directory repo-root t)
        (should (equal (beads-worktree-orchestrator--worktree-path repo-root "feature-x")
                       expected))))))

(ert-deftest bwo-test-worktree-path-strips-trailing-slash-from-repo-root ()
  (bwo-test--with-temp-dir root
    (let* ((ai-code-git-worktree-root root)
           (expected (expand-file-name "feature-x" (expand-file-name "some-repo" root))))
      (should (equal (beads-worktree-orchestrator--worktree-path "/tmp/parent/some-repo/" "feature-x")
                     expected))
      (should (equal (beads-worktree-orchestrator--worktree-path "/tmp/parent/some-repo" "feature-x")
                     expected)))))

;;; ---------------------------------------------------------------------
;;; --sync-file three-way comparison
;;; ---------------------------------------------------------------------

(defmacro bwo-test--with-sync-fixture (&rest body)
  "Run BODY with a fresh canonical (package) dir and skills-dir.

Rebinds `beads-worktree-orchestrator--package-dir',
`beads-worktree-orchestrator-skills-dir', and
`beads-worktree-orchestrator--skill-files' so `--sync-file' operates
entirely inside disposable temp directories."
  (declare (indent 0))
  `(bwo-test--with-temp-dir bwo-test--package-dir
     (bwo-test--with-temp-dir bwo-test--skills-dir
       (let ((beads-worktree-orchestrator--package-dir bwo-test--package-dir)
             (beads-worktree-orchestrator-skills-dir bwo-test--skills-dir)
             (beads-worktree-orchestrator--skill-files '("payload.txt")))
         ,@body))))

(defun bwo-test--installed-file ()
  (expand-file-name "payload.txt" (beads-worktree-orchestrator--installed-dir)))

(defun bwo-test--canonical-file ()
  (expand-file-name "payload.txt" beads-worktree-orchestrator--package-dir))

(defun bwo-test--state-file-copy ()
  (expand-file-name "payload.txt" (beads-worktree-orchestrator--state-dir)))

(ert-deftest bwo-test-sync-file-fresh-install ()
  (bwo-test--with-sync-fixture
    (bwo-test--write-file (bwo-test--canonical-file) "v1\n")
    (let ((result (beads-worktree-orchestrator--sync-file "payload.txt")))
      (should (eq (beads-worktree-orchestrator--sync-result-action result) 'installed))
      (should (beads-worktree-orchestrator--files-equal-p
               (bwo-test--installed-file) (bwo-test--canonical-file)))
      (should (beads-worktree-orchestrator--files-equal-p
               (bwo-test--state-file-copy) (bwo-test--canonical-file))))))

(ert-deftest bwo-test-sync-file-no-op-when-unedited-and-unchanged ()
  (bwo-test--with-sync-fixture
    (bwo-test--write-file (bwo-test--canonical-file) "v1\n")
    (beads-worktree-orchestrator--sync-file "payload.txt")
    (let ((result (beads-worktree-orchestrator--sync-file "payload.txt")))
      (should (eq (beads-worktree-orchestrator--sync-result-action result) 'unchanged))
      (should (equal (with-temp-buffer
                        (insert-file-contents (bwo-test--installed-file))
                        (buffer-string))
                     "v1\n")))))

(ert-deftest bwo-test-sync-file-silent-upgrade-when-unedited-and-upstream-changed ()
  (bwo-test--with-sync-fixture
    (bwo-test--write-file (bwo-test--canonical-file) "v1\n")
    (beads-worktree-orchestrator--sync-file "payload.txt")
    ;; Upstream changes; installed file is untouched by the user.
    (bwo-test--write-file (bwo-test--canonical-file) "v2\n")
    (let ((result (beads-worktree-orchestrator--sync-file "payload.txt")))
      (should (eq (beads-worktree-orchestrator--sync-result-action result) 'updated))
      (should (equal (with-temp-buffer
                        (insert-file-contents (bwo-test--installed-file))
                        (buffer-string))
                     "v2\n"))
      (should (beads-worktree-orchestrator--files-equal-p
               (bwo-test--state-file-copy) (bwo-test--canonical-file))))))

(ert-deftest bwo-test-sync-file-conflict-when-edited-and-upstream-changed ()
  (bwo-test--with-sync-fixture
    (bwo-test--write-file (bwo-test--canonical-file) "v1\n")
    (beads-worktree-orchestrator--sync-file "payload.txt")
    ;; User edits the installed copy AND upstream changes independently.
    (bwo-test--write-file (bwo-test--installed-file) "user edit\n")
    (bwo-test--write-file (bwo-test--canonical-file) "v2\n")
    (let ((result (beads-worktree-orchestrator--sync-file "payload.txt")))
      (should (eq (beads-worktree-orchestrator--sync-result-action result) 'conflict))
      (should (stringp (beads-worktree-orchestrator--sync-result-detail result)))
      ;; Installed file must NOT be silently clobbered.
      (should (equal (with-temp-buffer
                        (insert-file-contents (bwo-test--installed-file))
                        (buffer-string))
                     "user edit\n")))))

(ert-deftest bwo-test-sync-file-no-op-when-edited-but-upstream-unchanged ()
  (bwo-test--with-sync-fixture
    (bwo-test--write-file (bwo-test--canonical-file) "v1\n")
    (beads-worktree-orchestrator--sync-file "payload.txt")
    ;; User edits, but upstream never changed -> nothing to reconcile.
    (bwo-test--write-file (bwo-test--installed-file) "user edit\n")
    (let ((result (beads-worktree-orchestrator--sync-file "payload.txt")))
      (should (eq (beads-worktree-orchestrator--sync-result-action result) 'unchanged))
      (should (equal (with-temp-buffer
                        (insert-file-contents (bwo-test--installed-file))
                        (buffer-string))
                     "user edit\n")))))

;;; ---------------------------------------------------------------------
;;; --conflict-detail: git-tracked vs untracked branching
;;; ---------------------------------------------------------------------

(ert-deftest bwo-test-conflict-detail-untracked-writes-backup ()
  (bwo-test--with-temp-dir dir
    (let* ((installed (expand-file-name "payload.txt" dir))
           (canonical (expand-file-name "payload.new.txt" dir))
           (base (expand-file-name "payload.base.txt" dir))
           (backup (concat installed ".bak")))
      (bwo-test--write-file base "v1\n")
      (bwo-test--write-file installed "user edit\n")
      (bwo-test--write-file canonical "v2\n")
      (let ((detail (beads-worktree-orchestrator--conflict-detail
                     "payload.txt" base canonical installed)))
        (should (string-match-p "Not git-tracked" detail))
        (should (string-match-p (regexp-quote backup) detail))
        (should (file-exists-p backup))
        (should (equal (with-temp-buffer
                          (insert-file-contents backup)
                          (buffer-string))
                       "user edit\n"))))))

(ert-deftest bwo-test-conflict-detail-git-tracked-points-at-history ()
  (bwo-test--with-temp-dir dir
    (bwo-test--git dir "init" "-q" "-b" "main" ".")
    (bwo-test--git dir "config" "user.email" "test@example.com")
    (bwo-test--git dir "config" "user.name" "Test")
    (let* ((installed (expand-file-name "payload.txt" dir))
           (canonical (expand-file-name "payload.new.txt" dir))
           (base (expand-file-name "payload.base.txt" dir))
           (backup (concat installed ".bak")))
      (bwo-test--write-file base "v1\n")
      (bwo-test--write-file installed "user edit\n")
      (bwo-test--git dir "add" "payload.txt")
      (bwo-test--git dir "commit" "-q" "-m" "track payload")
      (bwo-test--write-file canonical "v2\n")
      (let ((detail (beads-worktree-orchestrator--conflict-detail
                     "payload.txt" base canonical installed)))
        (should (string-match-p "git-tracked" detail))
        (should (string-match-p "git .*log" detail))
        (should (string-match-p "git .*diff" detail))
        ;; Git-tracked path relies on history, not a .bak backup.
        (should-not (file-exists-p backup))))))

;;; ---------------------------------------------------------------------
;;; --start-worker-session: claude-code-ide bypass
;;; ---------------------------------------------------------------------

;; The real `ai-code' / `claude-code-ide' packages aren't loadable in this
;; batch test context, so stub just enough of their API surface for
;; `beads-worktree-orchestrator--start-worker-session' to call into.
;; Tests below override these with `cl-letf' to record what got called.

(defvar ai-code-selected-backend 'claude-code
  "Stub for tests; the real definition lives in ai-code-backends.el.")

(defun ai-code--effective-backend ()
  "Stub for tests; overridden per-test via `cl-letf'."
  ai-code-selected-backend)

(defun ai-code--activate-effective-backend ()
  "Stub for tests; overridden per-test via `cl-letf'.")

(defun ai-code--remember-current-backend-for-repo ()
  "Stub for tests; overridden per-test via `cl-letf'.")

(defun ai-code-cli-start ()
  "Stub for tests; overridden per-test via `cl-letf'.
Real implementation lives in ai-code-backends.el and itself dispatches to
`claude-code-ide--start-if-no-session' for the claude-code-ide backend —
the buggy wrapper `beads-worktree-orchestrator--start-worker-session' is
meant to bypass, which is exactly why tests assert this stub is NOT
called when the effective backend is `claude-code-ide'.")

(defun claude-code-ide ()
  "Stub for tests; overridden per-test via `cl-letf'.")

(defvar claude-code-ide-cli-extra-flags nil
  "Stub for tests; the real definition lives in claude-code-ide.el.
Must be declared `defvar' (special) here, not just `let'-bound, since
`beads-worktree-orchestrator--start-worker-session' dynamically rebinds
it and tests need that rebinding to actually take effect.")

(defmacro bwo-test--with-call-log (log-var &rest body)
  "Bind LOG-VAR to a list of call markers pushed onto during BODY."
  (declare (indent 1))
  `(let ((,log-var nil))
     ,@body))

(ert-deftest bwo-test-start-worker-session-uses-claude-code-ide-directly ()
  "When the effective backend is `claude-code-ide', call it directly,
bypassing `ai-code-cli-start' (and hence the buggy has-active-session-p
check inside `claude-code-ide--start-if-no-session')."
  (bwo-test--with-call-log calls
    (cl-letf (((symbol-function 'ai-code--effective-backend)
               (lambda () 'claude-code-ide))
              ((symbol-function 'ai-code--activate-effective-backend)
               (lambda () (push 'activate calls)))
              ((symbol-function 'ai-code--remember-current-backend-for-repo)
               (lambda () (push 'remember calls)))
              ((symbol-function 'claude-code-ide)
               (lambda () (push 'claude-code-ide-direct calls)))
              ((symbol-function 'ai-code-cli-start)
               (lambda () (push 'ai-code-cli-start calls)))
              (beads-worktree-orchestrator-worker-permission-mode nil))
      (beads-worktree-orchestrator--start-worker-session)
      (should (memq 'claude-code-ide-direct calls))
      (should-not (memq 'ai-code-cli-start calls))
      (should (memq 'activate calls))
      (should (memq 'remember calls)))))

(ert-deftest bwo-test-start-worker-session-uses-ai-code-cli-start-for-other-backends ()
  "For any backend other than `claude-code-ide', keep using the generic
`ai-code-cli-start' path — don't special-case other backends."
  (bwo-test--with-call-log calls
    (cl-letf (((symbol-function 'ai-code--effective-backend)
               (lambda () 'claude-code))
              ((symbol-function 'ai-code--activate-effective-backend)
               (lambda () (push 'activate calls)))
              ((symbol-function 'ai-code--remember-current-backend-for-repo)
               (lambda () (push 'remember calls)))
              ((symbol-function 'claude-code-ide)
               (lambda () (push 'claude-code-ide-direct calls)))
              ((symbol-function 'ai-code-cli-start)
               (lambda () (push 'ai-code-cli-start calls)))
              (beads-worktree-orchestrator-worker-permission-mode nil))
      (beads-worktree-orchestrator--start-worker-session)
      (should (memq 'ai-code-cli-start calls))
      (should-not (memq 'claude-code-ide-direct calls)))))

(ert-deftest bwo-test-start-worker-session-pre-approves-permissions-on-direct-path ()
  "The `--permission-mode' pre-approval flag still applies when the direct
`claude-code-ide' path is taken, not just the `ai-code-cli-start' path."
  (bwo-test--with-call-log calls
    (let ((claude-code-ide-cli-extra-flags ""))
      (cl-letf (((symbol-function 'ai-code--effective-backend)
                 (lambda () 'claude-code-ide))
                ((symbol-function 'ai-code--activate-effective-backend)
                 (lambda ()))
                ((symbol-function 'ai-code--remember-current-backend-for-repo)
                 (lambda ()))
                ((symbol-function 'claude-code-ide)
                 (lambda () (push claude-code-ide-cli-extra-flags calls)))
                ((symbol-function 'ai-code-cli-start)
                 (lambda () (push 'ai-code-cli-start calls)))
                (beads-worktree-orchestrator-worker-permission-mode "bypassPermissions"))
        (beads-worktree-orchestrator--start-worker-session)
        (should (member "--permission-mode bypassPermissions" calls))))))

;;; ---------------------------------------------------------------------
;;; --head-sha
;;; ---------------------------------------------------------------------

(ert-deftest bwo-test-head-sha ()
  (bwo-test--with-temp-dir dir
    (bwo-test--git dir "init" "-q" "-b" "main" ".")
    (bwo-test--git dir "config" "user.email" "test@example.com")
    (bwo-test--git dir "config" "user.name" "Test")
    (bwo-test--write-file (expand-file-name "f.txt" dir) "hi\n")
    (bwo-test--git dir "add" "f.txt")
    (bwo-test--git dir "commit" "-q" "-m" "init")
    (let ((expected (with-temp-buffer
                      (let ((default-directory dir))
                        (call-process "git" nil t nil "rev-parse" "main"))
                      (string-trim (buffer-string)))))
      (should (equal (beads-worktree-orchestrator--head-sha dir "main") expected)))))

(ert-deftest bwo-test-head-sha-unknown-branch-errors ()
  (bwo-test--with-temp-dir dir
    (bwo-test--git dir "init" "-q" "-b" "main" ".")
    (should-error (beads-worktree-orchestrator--head-sha dir "does-not-exist"))))

;;; ---------------------------------------------------------------------
;;; spawn-reviewer
;;; ---------------------------------------------------------------------

(ert-deftest bwo-test-spawn-reviewer-creates-detached-worktree ()
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent)))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (bwo-test--git repo-root "checkout" "-q" "-b" "impl-branch")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "changed\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "impl work")
        (bwo-test--git repo-root "checkout" "-q" "main")
        (let ((expected-path (expand-file-name "review-impl-branch"
                                                (expand-file-name "my-repo" root))))
          (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                     (lambda () "session-started"))
                    ((symbol-function 'require)
                     (lambda (feature &rest _) feature)))
            (let ((result (beads-worktree-orchestrator-spawn-reviewer repo-root "impl-branch")))
              (should (file-directory-p expected-path))
              (should (string-match-p (regexp-quote expected-path) result))
              (should (string-match-p "impl-branch" result))
              (should (string-match-p "session-started" result))
              ;; Detached HEAD: no branch checked out in the review worktree.
              (should (equal (with-temp-buffer
                                (let ((default-directory expected-path))
                                  (call-process "git" nil t nil "symbolic-ref" "-q" "HEAD"))
                                (buffer-string))
                             ""))
              ;; Content matches the reviewed branch, not main.
              (should (equal (with-temp-buffer
                                (insert-file-contents (expand-file-name "f.txt" expected-path))
                                (buffer-string))
                             "changed\n")))))))))

(ert-deftest bwo-test-spawn-reviewer-sanitizes-slash-in-branch ()
  ;; my/spawn-agent-worktree always creates branches like
  ;; "agent/impl-bd-<id>" -- this is the realistic case, not an edge case.
  ;; "review-" + that branch must not be treated as a nested path by
  ;; expand-file-name.
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent))
             (branch "agent/impl-bd-42"))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (bwo-test--git repo-root "checkout" "-q" "-b" branch)
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "changed\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "impl work")
        (bwo-test--git repo-root "checkout" "-q" "main")
        (let* ((repo-worktree-root (expand-file-name "my-repo" root))
               (expected-path (expand-file-name "review-agent-impl-bd-42" repo-worktree-root))
               (nested-path (expand-file-name "review-agent/impl-bd-42" repo-worktree-root)))
          (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                     (lambda () "session-started"))
                    ((symbol-function 'require)
                     (lambda (feature &rest _) feature)))
            (let ((result (beads-worktree-orchestrator-spawn-reviewer repo-root branch)))
              (should (file-directory-p expected-path))
              (should-not (file-directory-p nested-path))
              (should (string-match-p (regexp-quote expected-path) result))
              ;; Flat directory: its parent is the repo's worktree root,
              ;; not an intermediate "review-agent" directory.
              (should (equal (file-name-directory (directory-file-name expected-path))
                             (file-name-as-directory repo-worktree-root))))))))))

(ert-deftest bwo-test-spawn-reviewer-errors-if-worktree-exists ()
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent)))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (let ((existing (expand-file-name "review-main" (expand-file-name "my-repo" root))))
          (make-directory existing t)
          (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                     (lambda () "session-started"))
                    ((symbol-function 'require)
                     (lambda (feature &rest _) feature)))
            (should-error (beads-worktree-orchestrator-spawn-reviewer repo-root "main"))))))))

;;; ---------------------------------------------------------------------
;;; --wait-for-mcp-ready / spawn-and-send-prompt
;;; ---------------------------------------------------------------------

;; Stubs for MCP, send-prompt, and vterm APIs, which aren't loadable in batch context.

(defvar vterm-copy-mode nil
  "Stub variable; the real one is created by `define-minor-mode' in vterm.el.")

(defun vterm-copy-mode (&optional _arg)
  "Stub; overridden per-test via `cl-letf'.")

(defun claude-code-ide--get-buffer-name (&optional _directory)
  "Stub; overridden per-test via `cl-letf'.")

(defun claude-code-ide--display-buffer-in-side-window (_buffer)
  "Stub; overridden per-test via `cl-letf'.")

(defun claude-code-ide-mcp--get-session-for-project (_project-dir)
  "Stub; overridden per-test via `cl-letf'.")

(cl-defstruct bwo-test--fake-session client)

(defun claude-code-ide-mcp-session-client (_session)
  "Stub; overridden per-test via `cl-letf'.")

(defun claude-code-ide-send-prompt (&optional _prompt)
  "Stub; overridden per-test via `cl-letf'.")

(ert-deftest bwo-test-wait-for-mcp-ready-times-out ()
  "Returns nil when no MCP session appears within the timeout."
  (cl-letf (((symbol-function 'claude-code-ide-mcp--get-session-for-project)
             (lambda (_dir) nil)))
    (let ((beads-worktree-orchestrator-session-ready-timeout 0.6))
      (should-not (beads-worktree-orchestrator--wait-for-mcp-ready "/some/path/")))))

(ert-deftest bwo-test-wait-for-mcp-ready-returns-t-when-already-ready ()
  "Returns t immediately when MCP session already has a live client."
  (let* ((fake-session (make-bwo-test--fake-session :client 'mock-ws)))
    (cl-letf (((symbol-function 'claude-code-ide-mcp--get-session-for-project)
               (lambda (_dir) fake-session))
              ((symbol-function 'claude-code-ide-mcp-session-client)
               (lambda (s) (bwo-test--fake-session-client s))))
      (let ((beads-worktree-orchestrator-session-ready-timeout 5))
        (should (beads-worktree-orchestrator--wait-for-mcp-ready "/some/path/"))))))

(ert-deftest bwo-test-spawn-and-send-prompt-sends-prompt-when-ready ()
  "Sends the prompt via `claude-code-ide-send-prompt' when MCP becomes ready."
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent))
             (sent-prompts nil)
             (fake-session (make-bwo-test--fake-session :client 'mock-ws)))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                   (lambda () "session-started"))
                  ((symbol-function 'require)
                   (lambda (feature &rest _) feature))
                  ((symbol-function 'claude-code-ide-mcp--get-session-for-project)
                   (lambda (_dir) fake-session))
                  ((symbol-function 'claude-code-ide-mcp-session-client)
                   (lambda (s) (bwo-test--fake-session-client s)))
                  ((symbol-function 'claude-code-ide-send-prompt)
                   (lambda (p) (push p sent-prompts))))
          (let ((beads-worktree-orchestrator-post-ready-delay 0))
            (let ((result (beads-worktree-orchestrator-spawn-and-send-prompt
                           repo-root "feature-x" "do the thing")))
              (should (equal sent-prompts '("do the thing")))
              (should (string-match-p "sent opening prompt" result)))))))))

(ert-deftest bwo-test-setup-worker-scrollback-installs-keybindings ()
  "PageUp/PageDown get buffer-local bindings in a vterm-mode worker buffer."
  (bwo-test--with-temp-dir dir
    (let* ((dir (file-name-as-directory dir))
           (buf (get-buffer-create "*bwo-test-vterm-fake*")))
      (unwind-protect
          (with-current-buffer buf
            (let ((vterm-copy-mode nil))
              (cl-letf (((symbol-function 'derived-mode-p)
                         (lambda (mode &rest _) (eq mode 'vterm-mode)))
                        ((symbol-function 'claude-code-ide--get-buffer-name)
                         (lambda (_d) "*bwo-test-vterm-fake*")))
                (beads-worktree-orchestrator--setup-worker-scrollback dir)
                (should (local-key-binding (kbd "<prior>")))
                (should (local-key-binding (kbd "<next>")))
                ;; Bindings point at the named helpers, not anonymous lambdas.
                (should (eq (local-key-binding (kbd "<prior>"))
                            #'beads-worktree-orchestrator--enter-scroll-mode))
                (should (eq (local-key-binding (kbd "<next>"))
                            #'beads-worktree-orchestrator--exit-scroll-mode)))))
        (kill-buffer buf)))))

(ert-deftest bwo-test-enter-scroll-mode-calls-evil-normal-state ()
  "enter-scroll-mode calls evil-normal-state when evil is available."
  (let ((vterm-copy-mode nil)
        (evil-called nil))
    (cl-letf (((symbol-function 'vterm-copy-mode) (lambda (_) nil))
              ((symbol-function 'scroll-down-command) (lambda () nil))
              ((symbol-function 'evil-normal-state) (lambda () (setq evil-called t))))
      (beads-worktree-orchestrator--enter-scroll-mode)
      (should evil-called))))

(ert-deftest bwo-test-exit-scroll-mode-calls-evil-insert-state-at-bottom ()
  "exit-scroll-mode switches back to evil insert state when leaving copy-mode."
  (let ((vterm-copy-mode t)
        (insert-called nil))
    (cl-letf (((symbol-function 'scroll-up-command) (lambda () (signal 'end-of-buffer nil)))
              ((symbol-function 'vterm-copy-mode) (lambda (_) nil))
              ((symbol-function 'evil-insert-state) (lambda () (setq insert-called t))))
      (beads-worktree-orchestrator--exit-scroll-mode)
      (should insert-called))))

(ert-deftest bwo-test-setup-worker-scrollback-no-ops-when-buffer-missing ()
  "Silently does nothing when the session buffer doesn't exist."
  (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
             (lambda (_d) "*bwo-test-nonexistent-buffer*")))
    ;; Should not signal an error.
    (should (eq nil (beads-worktree-orchestrator--setup-worker-scrollback "/some/path/")))))

(ert-deftest bwo-test-spawn-and-send-prompt-calls-setup-scrollback ()
  "spawn-and-send-prompt calls --setup-worker-scrollback when MCP is ready."
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent))
             (scrollback-calls nil)
             (fake-session (make-bwo-test--fake-session :client 'mock-ws)))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                   (lambda () "session-started"))
                  ((symbol-function 'require)
                   (lambda (feature &rest _) feature))
                  ((symbol-function 'claude-code-ide-mcp--get-session-for-project)
                   (lambda (_dir) fake-session))
                  ((symbol-function 'claude-code-ide-mcp-session-client)
                   (lambda (s) (bwo-test--fake-session-client s)))
                  ((symbol-function 'claude-code-ide-send-prompt)
                   (lambda (_p) nil))
                  ((symbol-function 'beads-worktree-orchestrator--setup-worker-scrollback)
                   (lambda (path) (push path scrollback-calls))))
          (let ((beads-worktree-orchestrator-post-ready-delay 0))
            (beads-worktree-orchestrator-spawn-and-send-prompt
             repo-root "feature-x" "do the thing")
            (should (= 1 (length scrollback-calls)))))))))

(ert-deftest bwo-test-spawn-and-send-prompt-warns-on-timeout ()
  "Returns a warning string and does not call send-prompt when MCP times out."
  (bwo-test--with-temp-dir root
    (bwo-test--with-temp-dir repo-parent
      (let* ((ai-code-git-worktree-root root)
             (repo-root (expand-file-name "my-repo/" repo-parent))
             (sent-prompts nil))
        (make-directory repo-root t)
        (bwo-test--git repo-root "init" "-q" "-b" "main" ".")
        (bwo-test--git repo-root "config" "user.email" "test@example.com")
        (bwo-test--git repo-root "config" "user.name" "Test")
        (bwo-test--write-file (expand-file-name "f.txt" repo-root) "hi\n")
        (bwo-test--git repo-root "add" "f.txt")
        (bwo-test--git repo-root "commit" "-q" "-m" "init")
        (cl-letf (((symbol-function 'beads-worktree-orchestrator--start-worker-session)
                   (lambda () "session-started"))
                  ((symbol-function 'require)
                   (lambda (feature &rest _) feature))
                  ((symbol-function 'claude-code-ide-mcp--get-session-for-project)
                   (lambda (_dir) nil))
                  ((symbol-function 'claude-code-ide-send-prompt)
                   (lambda (p) (push p sent-prompts))))
          (let ((beads-worktree-orchestrator-session-ready-timeout 0.6))
            (let ((result (beads-worktree-orchestrator-spawn-and-send-prompt
                           repo-root "feature-y" "do the thing")))
              (should (null sent-prompts))
              (should (string-match-p "WARNING" result))
              (should (string-match-p "prompt not sent" result)))))))))

(provide 'beads-worktree-orchestrator-test)

;;; beads-worktree-orchestrator-test.el ends here
