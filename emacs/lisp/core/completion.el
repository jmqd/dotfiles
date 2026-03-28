;;; completion.el -*- lexical-binding: t; -*-

(use-package savehist
  :ensure nil
  :init
  (savehist-mode 1))

(use-package recentf
  :ensure nil
  :init
  (recentf-mode 1)
  :config
  (setq recentf-max-saved-items 200))

(use-package vertico
  :init
  (setq vertico-cycle t)
  (vertico-mode 1)
  :config
  (define-key vertico-map (kbd "H-i") #'vertico-previous)
  (define-key vertico-map (kbd "C-k") #'vertico-next))

(use-package orderless
  :init
  (setq completion-styles '(orderless basic)
        completion-category-defaults nil
        completion-category-overrides '((file (styles basic partial-completion)))))

(use-package marginalia
  :after vertico
  :init
  (marginalia-mode 1))

(use-package consult
  :after (vertico recentf))

(provide 'jmq-completion)
