;;; shell.el -*- lexical-binding: t; -*-

(use-package eshell
  :ensure nil
  :init
  (setq eshell-scroll-to-bottom-on-input 'all
        eshell-buffer-maximum-lines 20000
        eshell-history-size 1000000
        eshell-error-if-no-glob t
        eshell-hist-ignoredups t
        eshell-save-history-on-exit t))

(provide 'jmq-shell)
