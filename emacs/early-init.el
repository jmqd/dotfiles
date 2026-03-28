;;; early-init.el -*- lexical-binding: t; -*-

(setq package-enable-at-startup nil
      inhibit-startup-message t
      inhibit-startup-screen t
      initial-scratch-message nil
      frame-inhibit-implied-resize t
      native-comp-async-report-warnings-errors 'silent)

(menu-bar-mode -1)

(when (fboundp 'scroll-bar-mode)
  (scroll-bar-mode -1))

(when (fboundp 'tool-bar-mode)
  (tool-bar-mode -1))
