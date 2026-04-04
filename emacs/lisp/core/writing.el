;;; writing.el -*- lexical-binding: t; -*-

(defvar jmq/spell-checker-warning-shown nil
  "Whether the missing spell checker warning has already been shown.")

(defun jmq/find-spell-checker ()
  "Return the preferred spell checker binary, if available."
  (or (executable-find "aspell")
      (executable-find "hunspell")))

(defun jmq/ensure-spell-checker ()
  "Ensure a spell checker is available for Flyspell.

Return non-nil when spell checking can be enabled."
  (if-let ((spell-checker (or ispell-program-name (jmq/find-spell-checker))))
      (progn
        (setq ispell-program-name spell-checker)
        t)
    (unless jmq/spell-checker-warning-shown
      (setq jmq/spell-checker-warning-shown t)
      (message "No spell checker found on PATH; enable Home Manager to install aspell."))
    nil))

(defun jmq/enable-spell-checking ()
  "Enable spell checking appropriate for the current buffer."
  (interactive)
  (when (jmq/ensure-spell-checker)
    (if (derived-mode-p 'prog-mode)
        (flyspell-prog-mode)
      (flyspell-mode 1))))

(defun jmq/toggle-spell-checking ()
  "Toggle spell checking for the current buffer.

Programming buffers use `flyspell-prog-mode'; other buffers use
`flyspell-mode'."
  (interactive)
  (if flyspell-mode
      (flyspell-mode -1)
    (jmq/enable-spell-checking)))

(use-package flyspell
  :ensure nil
  :hook ((text-mode . jmq/enable-spell-checking)
         (prog-mode . jmq/enable-spell-checking)
         (git-commit-mode . jmq/enable-spell-checking))
  :init
  (setq ispell-program-name (jmq/find-spell-checker)
        ispell-dictionary "en_US"
        ispell-personal-dictionary (expand-file-name "ispell-personal.pws" jmq/var-directory)
        flyspell-issue-message-flag nil
        flyspell-issue-welcome-flag nil
        flyspell-sort-corrections nil))

(use-package langtool
  :commands (langtool-check
             langtool-check-buffer
             langtool-check-done
             langtool-correct-buffer
             langtool-show-message-at-point
             langtool-switch-default-language)
  :init
  (setq langtool-bin (or (executable-find "languagetool-commandline")
                         (executable-find "languagetool")
                         "languagetool-commandline")
        langtool-default-language "en-US"
        langtool-mother-tongue "en"))

(provide 'jmq-writing)
