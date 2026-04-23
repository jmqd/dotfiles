;;; org.el -*- lexical-binding: t; -*-

(defun jmq/from-org-to-textile-buffer ()
  "Convert the current buffer from Org to Jira/Textile markup in place."
  (interactive)
  (let ((pandoc (executable-find "pandoc")))
    (unless pandoc
      (user-error "pandoc is required for Org → Jira/Textile export; install it first"))
    (shell-command-on-region
     (point-min)
     (point-max)
     (format "%s -f org -t jira" (shell-quote-argument pandoc))
     t
     t)))

(defun jmq/org-redisplay-inline-images ()
  "Refresh inline images after Babel execution."
  (when org-inline-image-overlays
    (org-redisplay-inline-images)))

(use-package org
  :ensure nil
  :config
  (require 'ox-md)
  (add-hook 'org-babel-after-execute-hook #'jmq/org-redisplay-inline-images)
  (jmq/local-leader-keys
    :keymaps 'org-mode-map
    "e" '(:ignore t :which-key "export")
    "ee" '(org-export-dispatch :which-key "dispatch")
    "eh" '(org-html-export-to-html :which-key "html")
    "el" '(org-latex-export-to-pdf :which-key "pdf")
    "em" '(org-md-export-to-markdown :which-key "markdown")
    "er" '(org-reveal-export-to-html :which-key "reveal.js")
    "et" '(jmq/from-org-to-textile-buffer :which-key "jira/textile")))

(use-package htmlize
  :after org)

(use-package ox-reveal
  :after org)

(provide 'jmq-org)
