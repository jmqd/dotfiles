;;; snippets.el -*- lexical-binding: t; -*-

(defun jmq/auto-insert-emacs-lisp ()
  "Insert a minimal Emacs Lisp file skeleton."
  (let* ((file-name (file-name-nondirectory (or (buffer-file-name) "module.el")))
         (feature-name (replace-regexp-in-string "_" "-" (file-name-base file-name))))
    (insert ";;; " file-name " -*- lexical-binding: t; -*-\n\n")
    (save-excursion
      (insert "\n(provide '" feature-name ")\n"))))

(defun jmq/auto-insert-shell-script ()
  "Insert a minimal shell script skeleton."
  (insert "#!/usr/bin/env bash\nset -euo pipefail\n\n"))

(use-package yasnippet
  :hook ((prog-mode . yas-minor-mode)
         (text-mode . yas-minor-mode))
  :config
  (yas-reload-all))

(use-package yasnippet-snippets
  :after yasnippet)

(use-package autoinsert
  :ensure nil
  :init
  (setq auto-insert-query t)
  :config
  (auto-insert-mode 1)
  (define-auto-insert 'emacs-lisp-mode #'jmq/auto-insert-emacs-lisp)
  (define-auto-insert 'sh-mode #'jmq/auto-insert-shell-script))

(use-package executable
  :ensure nil
  :hook (after-save . executable-make-buffer-file-executable-if-script-p))

(provide 'jmq-snippets)
