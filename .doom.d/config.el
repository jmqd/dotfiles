;;; $DOOMDIR/config.el -*- lexical-binding: t; -*-

;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets.
(setq user-full-name "Jordan McQueen"
      user-mail-address "j@jm.dev")

;; Because Ctrl-I and <TAB> are actually the same control character,
;; remap Ctrl-I to Hyper-I, so I can use it later.
(keyboard-translate ?\C-i ?\H-i)

;; Doom exposes five (optional) variables for controlling fonts in Doom. Here
;; are the three important ones:
;;
;; + `doom-font'
;; + `doom-variable-pitch-font'
;; + `doom-big-font' -- used for `doom-big-font-mode'; use this for
;;   presentations or streaming.
;;
;; They all accept either a font-spec, font string ("Input Mono-12"), or xlfd
;; font string. You generally only need these two:
;; (setq doom-font (font-spec :family "monospace" :size 12 :weight 'semi-light)
;;       doom-variable-pitch-font (font-spec :family "sans" :size 13))
(setq doom-font (font-spec :family "monospace" :size 24))

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-plain)

;; ijkl arrow-style navigations
(define-key evil-normal-state-map "i" 'evil-previous-line)
(define-key evil-normal-state-map "j" 'evil-backward-char)
(define-key evil-normal-state-map "k" 'evil-next-line)
(define-key evil-normal-state-map "h" 'evil-insert)
(define-key evil-motion-state-map "i" 'evil-previous-line)
(define-key evil-motion-state-map "j" 'evil-backward-char)
(define-key evil-motion-state-map "k" 'evil-next-line)
(define-key evil-visual-state-map "i" 'evil-previous-visual-line)
(define-key evil-visual-state-map "k" 'evil-next-visual-line)
(define-key evil-visual-state-map "k" 'evil-next-visual-line)

(define-key minibuffer-mode-map (kbd "C-k") 'next-line)
(define-key minibuffer-mode-map (kbd "H-i") 'previous-line)
(define-key minibuffer-mode-map (kbd "C-j") 'backward-char)
(define-key minibuffer-mode-map (kbd "C-l") 'forward-char)
(define-key minibuffer-local-map (kbd "C-k") 'next-line)
(define-key minibuffer-local-map (kbd "H-i") 'previous-line)
(define-key vertico-map (kbd "H-i") 'vertico-previous)
(define-key vertico-map (kbd "C-k") 'vertico-next)

(with-eval-after-load 'company
  (define-key company-active-map (kbd "H-i") 'company-select-previous)
  (define-key company-active-map (kbd "C-k") 'company-select-next)
  (define-key company-search-map (kbd "H-i") 'company-select-previous)
  (define-key company-search-map (kbd "C-k") 'company-select-next)
  )

(map! :after evil :map grep-mode-map
      :g "C-k" #'next-error-no-select
      :g (kbd "H-i") #'previous-error-no-select)

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type 'relative)

;; major-mode leader key
(setq doom-localleader-key ",")

;; If you use `org' and don't want your org files in the default location below,
;; change `org-directory'. It must be set before org loads!
(setq org-directory "~/cloud/mcqueen.jordan/")

(setq plantuml-output-type "png")

(with-eval-after-load 'lsp-rust
  (require 'dap-cpptools))

(with-eval-after-load 'dap-cpptools
  ;; Add a template specific for debugging Rust programs.
  ;; It is used for new projects, where I can M-x dap-edit-debug-template
  (dap-register-debug-template "Rust::CppTools Run Configuration"
                               (list :type "cppdbg"
                                     :request "launch"
                                     :name "Rust::Run"
                                     :MIMode "gdb"
                                     :miDebuggerPath "rust-gdb"
                                     :environment []
                                     :program
                                     "${workspaceFolder}/target/debug/hello / replace with binary"
                                     :cwd "${workspaceFolder}"
                                     :console "external"
                                     :dap-compilation "cargo build"
                                     :dap-compilation-dir "${workspaceFolder}")))

(with-eval-after-load 'dap-mode
  (setq dap-default-terminal-kind "integrated") ;; Make sure that
  terminal programs open a term for I/O in an Emacs buffer
  (dap-auto-configure-mode +1))

(after! org
  (load-library "ox-reveal"))

(defun from-org-to-textile-buffer ()
  "Converts the contents of the buffer from org to textile."
  (interactive)
  (shell-command-on-region
   (point-min) (point-max)
   "pandoc -f org -t jira" t t))

(add-hook 'org-babel-after-execute-hook
          (lambda ()
            (when org-inline-image-overlays
              (org-redisplay-inline-images))))

;; Here are some additional functions/macros that could help you configure Doom:
;;
;; - `load!' for loading external *.el files relative to this one
;; - `use-package!' for configuring packages
;; - `after!' for running code after a package has loaded
;; - `add-load-path!' for adding directories to the `load-path', relative to
;;   this file. Emacs searches the `load-path' when you load packages with
;;   `require' or `use-package'.
;; - `map!' for binding new keys
;;
;; To get information about any of these functions/macros, move the cursor over
;; the highlighted symbol at press 'K' (non-evil users must press 'C-c c k').
;; This will open documentation for it, including demos of how they are used.
;;
;; You can also try 'gd' (or 'C-c c d') to jump to their definition and see how
;; they are implemented.
