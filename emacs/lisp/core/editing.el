;;; editing.el -*- lexical-binding: t; -*-

(setq evil-want-integration t
      evil-want-keybinding nil
      evil-undo-system 'undo-redo)

(defun jmq/apply-evil-directional-bindings ()
  "Restore the `ijkl` navigation layout used in the Doom config."
  (define-key evil-normal-state-map "i" #'evil-previous-line)
  (define-key evil-normal-state-map "j" #'evil-backward-char)
  (define-key evil-normal-state-map "k" #'evil-next-line)
  (define-key evil-normal-state-map "h" #'evil-insert)
  (define-key evil-motion-state-map "i" #'evil-previous-line)
  (define-key evil-motion-state-map "j" #'evil-backward-char)
  (define-key evil-motion-state-map "k" #'evil-next-line)
  (define-key evil-visual-state-map "i" #'evil-previous-visual-line)
  (define-key evil-visual-state-map "k" #'evil-next-visual-line))

(defun jmq/apply-minibuffer-directional-bindings ()
  "Restore the old minibuffer navigation muscle memory."
  (dolist (map (list minibuffer-mode-map
                     minibuffer-local-map
                     minibuffer-local-completion-map
                     minibuffer-local-must-match-map
                     minibuffer-local-isearch-map))
    (define-key map (kbd "C-k") #'next-line)
    (define-key map (kbd "H-i") #'previous-line)
    (define-key map (kbd "C-j") #'backward-char)
    (define-key map (kbd "C-l") #'forward-char)))

(use-package evil
  :demand t
  :config
  (evil-mode 1))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init)
  (jmq/apply-evil-directional-bindings))

(jmq/apply-minibuffer-directional-bindings)

(provide 'jmq-editing)
