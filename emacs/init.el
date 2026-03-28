;;; init.el -*- lexical-binding: t; -*-

(let ((core-dir (expand-file-name "lisp/core" user-emacs-directory)))
  (load (expand-file-name "bootstrap.el" core-dir) nil 'nomessage)
  (load (expand-file-name "defaults.el" core-dir) nil 'nomessage)
  (load (expand-file-name "editing.el" core-dir) nil 'nomessage)
  (load (expand-file-name "completion.el" core-dir) nil 'nomessage)
  (load (expand-file-name "leader.el" core-dir) nil 'nomessage)
  (load (expand-file-name "prog.el" core-dir) nil 'nomessage)
  (load (expand-file-name "vcs.el" core-dir) nil 'nomessage)
  (load (expand-file-name "org.el" core-dir) nil 'nomessage))
