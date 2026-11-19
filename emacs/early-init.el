;;; early-init.el -*- lexical-binding: t; -*-

(defconst jmq/default-file-name-handler-alist file-name-handler-alist)

(setq gc-cons-threshold (* 64 1024 1024)
      file-name-handler-alist nil)

(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 16 1024 1024)
                  file-name-handler-alist jmq/default-file-name-handler-alist)))

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

(push '(menu-bar-lines . 0) default-frame-alist)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)
