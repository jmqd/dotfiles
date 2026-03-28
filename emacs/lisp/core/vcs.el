;;; vcs.el -*- lexical-binding: t; -*-

(use-package magit
  :commands (magit-status)
  :config
  (setq magit-list-refs-sortby "-committerdate")
  (dolist
      (map-symbol
       '(magit-mode-map
         magit-section-mode-map
         magit-status-mode-map
         magit-log-mode-map
         magit-diff-mode-map
         magit-process-mode-map
         magit-revision-mode-map
         magit-reflog-mode-map
         magit-refs-mode-map
         magit-blame-mode-map
         magit-blame-read-only-mode-map
         magit-commit-section-map
         magit-commit-message-section-map
         magit-diff-section-map
         magit-file-section-map
         magit-hunk-section-map
         magit-log-section-map
         magit-staged-section-map
         magit-stash-section-map
         magit-stashes-section-map
         magit-unstaged-section-map
         magit-untracked-section-map))
    (when (boundp map-symbol)
      (define-key (symbol-value map-symbol) (kbd "C-k") #'magit-section-forward)
      (define-key (symbol-value map-symbol) (kbd "H-i") #'magit-section-backward))))

(with-eval-after-load 'grep
  (define-key grep-mode-map (kbd "C-k") #'next-error-no-select)
  (define-key grep-mode-map (kbd "H-i") #'previous-error-no-select))

(provide 'jmq-vcs)
