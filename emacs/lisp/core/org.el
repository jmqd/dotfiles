;;; org.el -*- lexical-binding: t; -*-

(defun jmq/from-org-to-textile-buffer ()
  "Convert the current buffer from Org to Jira/Textile markup in place."
  (interactive)
  (shell-command-on-region
   (point-min)
   (point-max)
   "pandoc -f org -t jira"
   t
   t))

(defun jmq/org-redisplay-inline-images ()
  "Refresh inline images after Babel execution."
  (when org-inline-image-overlays
    (org-redisplay-inline-images)))

(use-package org
  :ensure nil
  :config
  (add-hook 'org-babel-after-execute-hook #'jmq/org-redisplay-inline-images))

(provide 'jmq-org)
