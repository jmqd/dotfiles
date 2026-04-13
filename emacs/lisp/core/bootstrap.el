;;; bootstrap.el -*- lexical-binding: t; -*-

(when (< emacs-major-version 29)
  (user-error "The handcrafted Emacs config currently targets Emacs 29+; current binary is %s" emacs-version))

(require 'package)

(setq package-user-dir (expand-file-name "var/elpa" user-emacs-directory)
      package-archives
      '(("gnu" . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa" . "https://melpa.org/packages/")))

(package-initialize)

(defvar jmq/package-install-refresh-attempted nil
  "Whether package installation has already retried after refreshing archives.")

(defun jmq/package-install-with-refresh-once (fn package &rest args)
  "Call FN to install PACKAGE, refreshing archives once on failure."
  (condition-case err
      (apply fn package args)
    (error
     (if jmq/package-install-refresh-attempted
         (signal (car err) (cdr err))
       (setq jmq/package-install-refresh-attempted t)
       (message "Package install failed for %s; refreshing archives and retrying: %s"
                package
                (error-message-string err))
       (package-refresh-contents)
       (apply fn package args)))))

(advice-add 'package-install :around #'jmq/package-install-with-refresh-once)

(unless (package-installed-p 'use-package)
  (unless package-archive-contents
    (package-refresh-contents))
  (package-install 'use-package))

(require 'use-package)

(setq use-package-always-ensure t
      use-package-expand-minimally t
      use-package-compute-statistics t)

(provide 'jmq-bootstrap)
