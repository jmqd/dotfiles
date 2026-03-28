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

(unless (package-installed-p 'use-package)
  (unless package-archive-contents
    (package-refresh-contents))
  (package-install 'use-package))

(require 'use-package)

(setq use-package-always-ensure t
      use-package-expand-minimally t
      use-package-compute-statistics t)

(provide 'jmq-bootstrap)
