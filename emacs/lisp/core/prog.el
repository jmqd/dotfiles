;;; prog.el -*- lexical-binding: t; -*-

(use-package exec-path-from-shell
  :if (eq system-type 'darwin)
  :demand t
  :config
  (dolist (var '("LANG" "LC_ALL" "LC_CTYPE" "OSFONTDIR"))
    (add-to-list 'exec-path-from-shell-variables var))
  (exec-path-from-shell-initialize))

(defun jmq/setup-corfu-navigation ()
  "Preserve the old vertical navigation muscle memory inside completion UIs."
  (define-key corfu-map (kbd "H-i") #'corfu-previous)
  (define-key corfu-map (kbd "C-k") #'corfu-next)
  (define-key corfu-map (kbd "TAB") #'corfu-complete)
  (define-key corfu-map (kbd "<tab>") #'corfu-complete))

(defun jmq/eglot-rename ()
  "Rename symbol at point using Eglot."
  (interactive)
  (call-interactively #'eglot-rename))

(defun jmq/eglot-format ()
  "Format the current buffer using the active language server."
  (interactive)
  (call-interactively #'eglot-format-buffer))

(defun jmq/eglot-code-actions ()
  "Run code actions for the current region or point."
  (interactive)
  (call-interactively #'eglot-code-actions))

(use-package corfu
  :init
  (setq corfu-auto t
        corfu-auto-delay 0.1
        corfu-auto-prefix 1
        corfu-cycle t
        corfu-preview-current nil
        tab-always-indent 'complete)
  (global-corfu-mode 1)
  :config
  (jmq/setup-corfu-navigation)
  (corfu-popupinfo-mode 1)
  (corfu-history-mode 1))

(use-package kind-icon
  :after corfu
  :config
  (setq kind-icon-default-face 'corfu-default)
  (add-to-list 'corfu-margin-formatters #'kind-icon-margin-formatter))

(use-package cape
  :after corfu
  :config
  (add-hook 'completion-at-point-functions #'cape-dabbrev 20)
  (add-hook 'completion-at-point-functions #'cape-file 30))

(use-package eglot
  :hook
  ((c-mode . eglot-ensure)
   (c++-mode . eglot-ensure)
   (python-mode . eglot-ensure)
   (rust-mode . eglot-ensure)
   (go-mode . eglot-ensure)
   (js-mode . eglot-ensure)
   (js-ts-mode . eglot-ensure)
   (typescript-mode . eglot-ensure)
   (typescript-ts-mode . eglot-ensure)
   (nix-mode . eglot-ensure)
   (zig-mode . eglot-ensure))
  :config
  (setq eglot-autoshutdown t
        eglot-confirm-server-initiated-edits nil)
  (add-to-list 'eglot-server-programs
               '(python-mode . ("basedpyright-langserver" "--stdio")))
  (add-to-list 'eglot-server-programs
               '((rust-mode rustic-mode) . ("rustup" "run" "stable" "rust-analyzer")))
  (add-to-list 'eglot-server-programs
               '((go-mode go-ts-mode) . ("gopls")))
  (add-to-list 'eglot-server-programs
               '((nix-mode nix-ts-mode) . ("nil")))
  (add-to-list 'eglot-server-programs
               '((js-mode js-ts-mode typescript-mode typescript-ts-mode)
                 . ("typescript-language-server" "--stdio")))
  (add-to-list 'eglot-server-programs
               '(zig-mode . ("zls"))))

(use-package rust-mode
  :mode "\\.rs\\'")

(use-package go-mode
  :mode "\\.go\\'")

(use-package markdown-mode
  :mode (("README\\.md\\'" . gfm-mode)
         ("\\.md\\'" . markdown-mode)))

(use-package nix-mode
  :mode "\\.nix\\'")

(use-package plantuml-mode
  :mode (("\\.plantuml\\'" . plantuml-mode)
         ("\\.puml\\'" . plantuml-mode)
         ("\\.uml\\'" . plantuml-mode))
  :config
  (when-let ((plantuml (executable-find "plantuml")))
    (setq plantuml-default-exec-mode 'executable
          plantuml-executable-path plantuml)))

(use-package yaml-mode
  :mode "\\.ya?ml\\'")

(use-package zig-mode
  :mode (("\\.zig\\'" . zig-mode)
         ("\\.zon\\'" . zig-mode)))

(provide 'jmq-prog)
