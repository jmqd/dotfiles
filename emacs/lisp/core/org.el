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
  (add-hook 'org-babel-after-execute-hook #'jmq/org-redisplay-inline-images))

(provide 'jmq-org)
