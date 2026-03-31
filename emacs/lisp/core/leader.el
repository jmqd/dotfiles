;;; leader.el -*- lexical-binding: t; -*-

(use-package which-key
  :demand t
  :config
  (setq which-key-idle-delay 0.4)
  (which-key-mode 1))

(defun jmq/delete-file-and-buffer ()
  "Delete the current file and kill the buffer."
  (interactive)
  (let ((file (buffer-file-name)))
    (unless file (user-error "Buffer is not visiting a file"))
    (when (yes-or-no-p (format "Delete %s? " file))
      (delete-file file t)
      (kill-buffer))))

(defun jmq/yank-file-path ()
  "Copy the current buffer's file path to the kill ring."
  (interactive)
  (if-let ((path (buffer-file-name)))
      (progn (kill-new path) (message "%s" path))
    (user-error "Buffer is not visiting a file")))

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
    "`" '(evil-switch-to-windows-last-buffer :which-key "last buffer")
    "TAB" '(evil-switch-to-windows-last-buffer :which-key "last buffer")
    "/" '(consult-ripgrep :which-key "search project")
    "." '(find-file :which-key "find file")
    "," '(consult-buffer :which-key "switch buffer")
    "u" '(universal-argument :which-key "universal argument")

    "b" '(:ignore t :which-key "buffers")
    "bb" '(consult-buffer :which-key "switch buffer")
    "bd" '(kill-current-buffer :which-key "kill buffer")
    "bi" '(ibuffer :which-key "ibuffer")
    "bk" '(kill-current-buffer :which-key "kill buffer")

    "f" '(:ignore t :which-key "files")
    "fD" '(jmq/delete-file-and-buffer :which-key "delete file")
    "ff" '(find-file :which-key "find file")
    "fR" '(rename-visited-file :which-key "rename file")
    "fr" '(consult-recent-file :which-key "recent file")
    "fs" '(save-buffer :which-key "save file")
    "fy" '(jmq/yank-file-path :which-key "yank file path")

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
    "gb" '(magit-blame :which-key "blame")
    "gl" '(magit-log-current :which-key "log current")

    "h" '(:ignore t :which-key "help")
    "hf" '(describe-function :which-key "describe function")
    "hv" '(describe-variable :which-key "describe variable")
    "hk" '(describe-key :which-key "describe key")
    "hm" '(describe-mode :which-key "describe mode")

    "o" '(:ignore t :which-key "open")
    "op" '(project-eshell :which-key "project shell")

    "p" '(:ignore t :which-key "project")
    "p!" '(project-shell-command :which-key "shell command")
    "pb" '(consult-project-buffer :which-key "project buffer")
    "pe" '(project-eshell :which-key "project shell")
    "pf" '(project-find-file :which-key "find project file")
    "pp" '(project-switch-project :which-key "switch project")

    "s" '(:ignore t :which-key "search")
    "sg" '(consult-ripgrep :which-key "ripgrep")
    "ss" '(consult-line :which-key "search buffer")
    "si" '(consult-imenu :which-key "imenu")

    "w" '(:ignore t :which-key "windows")
    "ww" '(evil-window-next :which-key "next window")
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
