;;; bootstrap.el -*- lexical-binding: t; -*-

(when (< emacs-major-version 29)
  (user-error "The handcrafted Emacs config currently targets Emacs 29+; current binary is %s" emacs-version))

;; Packages come from `programs.emacs.extraPackages' in home/emacs.nix, pinned
;; by flake.lock. package.el only activates them from Nix's site-lisp; with no
;; archives it cannot download anything.
(require 'package)
(setq package-archives nil)
(package-initialize)

(require 'use-package)

(setq use-package-expand-minimally t
      use-package-compute-statistics t)

(provide 'jmq-bootstrap)
