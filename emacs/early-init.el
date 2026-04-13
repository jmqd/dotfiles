;;; early-init.el -*- lexical-binding: t; -*-

(let* ((var-dir (expand-file-name "var/" user-emacs-directory))
       (eln-cache-dir (expand-file-name "eln-cache/" var-dir)))
  (make-directory eln-cache-dir t)
  (when (fboundp 'startup-redirect-eln-cache)
    (startup-redirect-eln-cache eln-cache-dir)))

(setq package-enable-at-startup nil
      inhibit-startup-message t
      inhibit-startup-screen t
      initial-scratch-message nil
      frame-inhibit-implied-resize t
      native-comp-async-report-warnings-errors 'silent
      native-comp-warning-on-missing-source nil)

(menu-bar-mode -1)

(when (fboundp 'scroll-bar-mode)
  (scroll-bar-mode -1))

(when (fboundp 'tool-bar-mode)
  (tool-bar-mode -1))
