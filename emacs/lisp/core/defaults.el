;;; defaults.el -*- lexical-binding: t; -*-

(setq user-full-name "Jordan McQueen"
      user-mail-address "j@jm.dev")

;; Free up a distinct Hyper chord so the old Doom-era navigation muscle memory
;; can carry forward outside of Doom's key machinery.
(keyboard-translate ?\C-i ?\H-i)

(defconst jmq/var-directory
  (expand-file-name "var/" user-emacs-directory))

(unless (file-directory-p jmq/var-directory)
  (make-directory jmq/var-directory t))

(setq custom-file (expand-file-name "custom.el" jmq/var-directory)
      backup-directory-alist `(("." . ,(expand-file-name "backups/" jmq/var-directory)))
      auto-save-file-name-transforms `((".*" ,(expand-file-name "auto-save/" jmq/var-directory) t))
      recentf-save-file (expand-file-name "recentf" jmq/var-directory)
      savehist-file (expand-file-name "savehist" jmq/var-directory)
      ring-bell-function #'ignore
      org-directory "~/cloud/mcqueen.jordan/"
      plantuml-output-type "png")

(load custom-file 'noerror 'nomessage)

(defun jmq/apply-frame-defaults (&optional frame)
  "Apply UI defaults to FRAME or the currently selected frame."
  (with-selected-frame (or frame (selected-frame))
    (when (display-graphic-p)
      (condition-case nil
          (set-frame-font "Berkeley Mono-24" nil t)
        (error nil)))))

(add-hook 'emacs-startup-hook #'jmq/apply-frame-defaults)
(add-hook 'after-make-frame-functions #'jmq/apply-frame-defaults)

(setq-default display-line-numbers-type 'relative)
(global-display-line-numbers-mode 1)

(dolist (hook '(eshell-mode-hook shell-mode-hook term-mode-hook vterm-mode-hook))
  (add-hook hook (lambda () (display-line-numbers-mode -1))))

(provide 'jmq-defaults)
