;;; vcs.el -*- lexical-binding: t; -*-

(use-package magit
  :commands (magit-status)
  :config
  (setq magit-display-buffer-function #'magit-display-buffer-fullframe-status-v1)
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


(use-package sops
  :ensure nil
  :demand t
  :init
  ;; Upstream SOPS does not support structured TOML encryption. Treat *.toml
  ;; secrets as binary SOPS files so Emacs can still decrypt/edit/re-encrypt
  ;; the whole file transparently. JSON remains the boring native path.
  (setq sops-prefilter-regex "\\.\\(ya?ml\\|json\\|env\\|ini\\|txt\\|toml\\)\\'"
        sops-input-type-overrides '(("\\.toml\\'" . "binary")))
  :config
  (global-sops-mode 1))
(with-eval-after-load 'grep
  (define-key grep-mode-map (kbd "C-k") #'next-error-no-select)
  (define-key grep-mode-map (kbd "H-i") #'previous-error-no-select))

(provide 'jmq-vcs)
