;;; handcrafted-loader.el -*- lexical-binding: t; -*-

(setq user-emacs-directory
      (file-name-directory (or load-file-name buffer-file-name)))

(load (expand-file-name "early-init.el" user-emacs-directory) nil 'nomessage)
(load (expand-file-name "init.el" user-emacs-directory) nil 'nomessage)
