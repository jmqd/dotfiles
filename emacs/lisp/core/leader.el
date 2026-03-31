;;; leader.el -*- lexical-binding: t; -*-

(use-package which-key
  :demand t
  :config
  (setq which-key-idle-delay 0.4)
  (which-key-mode 1))

(use-package general
  :after evil
  :config
  (general-create-definer jmq/leader-keys
    :states '(normal motion visual)
    :keymaps 'override
    :prefix "SPC"
    :global-prefix "C-SPC")

  (general-create-definer jmq/local-leader-keys
    :states '(normal motion visual)
    :keymaps 'override
    :prefix ",")

  (jmq/leader-keys
    "SPC" '(execute-extended-command :which-key "M-x")
    ":" '(execute-extended-command :which-key "M-x")
    "." '(find-file :which-key "find file")
    "," '(consult-buffer :which-key "switch buffer")

    "b" '(:ignore t :which-key "buffers")
    "bb" '(consult-buffer :which-key "switch buffer")
    "bk" '(kill-current-buffer :which-key "kill buffer")

    "f" '(:ignore t :which-key "files")
    "ff" '(find-file :which-key "find file")
    "fr" '(consult-recent-file :which-key "recent file")

    "c" '(:ignore t :which-key "code")
    "ca" '(jmq/eglot-code-actions :which-key "code actions")
    "cd" '(xref-find-definitions :which-key "definition")
    "cD" '(xref-find-references :which-key "references")
    "cf" '(jmq/eglot-format :which-key "format buffer")
    "cr" '(jmq/eglot-rename :which-key "rename")

    "e" '(:ignore t :which-key "errors")
    "en" '(flymake-goto-next-error :which-key "next")
    "ep" '(flymake-goto-prev-error :which-key "previous")
    "el" '(consult-flymake :which-key "list")

    "g" '(:ignore t :which-key "git")
    "gg" '(magit-status :which-key "magit status")

    "p" '(:ignore t :which-key "project")
    "pp" '(project-switch-project :which-key "switch project")
    "pf" '(project-find-file :which-key "find project file")
    "pb" '(consult-project-buffer :which-key "project buffer")

    "s" '(:ignore t :which-key "search")
    "sg" '(consult-ripgrep :which-key "ripgrep")

    "w" '(:ignore t :which-key "windows")
    "wi" '(evil-window-up :which-key "up")
    "wj" '(evil-window-left :which-key "left")
    "wk" '(evil-window-down :which-key "down")
    "wl" '(evil-window-right :which-key "right")
    "ws" '(split-window-below :which-key "split below")
    "wv" '(split-window-right :which-key "split right")
    "wd" '(delete-window :which-key "delete")
    "wo" '(delete-other-windows :which-key "only")

    "q" '(:ignore t :which-key "quit")
    "qq" '(save-buffers-kill-terminal :which-key "quit emacs")))

(provide 'jmq-leader)
