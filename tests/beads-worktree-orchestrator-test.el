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

(provide 'beads-worktree-orchestrator-test)

;;; beads-worktree-orchestrator-test.el ends here
