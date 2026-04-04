;;; debug.el -*- lexical-binding: t; -*-

(require 'cl-lib)

(defun jmq/dap-lldb-binary ()
  "Return the preferred LLDB DAP binary."
  (or (executable-find "lldb-dap")
      (executable-find "lldb-vscode")
      "lldb-dap"))

(defun jmq/dap-gdb-binary ()
  "Return the preferred GDB binary."
  (or (executable-find "gdb")
      "gdb"))

(defun jmq/dap-register-template (name template)
  "Register TEMPLATE under NAME, replacing any existing entry."
  (setq dap-debug-template-configurations
        (cl-remove-if (lambda (config)
                        (equal name (plist-get config :name)))
                      dap-debug-template-configurations))
  (dap-register-debug-template name template))

(defun jmq/dap-native-template (name debugger-type program)
  "Build a launch template NAME using DEBUGGER-TYPE and PROGRAM."
  (list :type debugger-type
        :request "launch"
        :name name
        :program program
        :cwd "${workspaceFolder}"
        :args []))

(use-package dap-mode
  :commands (dap-breakpoint-toggle
             dap-continue
             dap-debug
             dap-debug-edit-template
             dap-debug-restart
             dap-disconnect
             dap-next
             dap-step-in
             dap-step-out)
  :init
  (setq dap-default-terminal-kind "integrated")
  :config
  (require 'dap-ui)
  (require 'dap-lldb)

  (setq dap-lldb-debug-program (list (jmq/dap-lldb-binary)))
  (dap-auto-configure-mode 1)

  (jmq/dap-register-template
   "Rust::LLDB Run"
   (jmq/dap-native-template
    "Rust::LLDB Run"
    "lldb-vscode"
    "${workspaceFolder}/target/debug/replace-with-binary"))

  (jmq/dap-register-template
   "C/C++::LLDB Run"
   (jmq/dap-native-template
    "C/C++::LLDB Run"
    "lldb-vscode"
    "${workspaceFolder}/replace-with-binary"))

  (if (eq system-type 'gnu/linux)
      (progn
        (require 'dap-gdb)
        (setq dap-gdb-debug-program (list (jmq/dap-gdb-binary) "-i" "dap"))

        (jmq/dap-register-template
         "Rust::GDB Run"
         (jmq/dap-native-template
          "Rust::GDB Run"
          "gdb"
          "${workspaceFolder}/target/debug/replace-with-binary"))

        (jmq/dap-register-template
         "C/C++::GDB Run"
         (jmq/dap-native-template
          "C/C++::GDB Run"
          "gdb"
          "${workspaceFolder}/replace-with-binary"))

        (jmq/dap-register-template
         "Rust::Run"
         (jmq/dap-native-template
          "Rust::Run"
          "gdb"
          "${workspaceFolder}/target/debug/replace-with-binary"))

        (jmq/dap-register-template
         "C/C++::Run"
         (jmq/dap-native-template
          "C/C++::Run"
          "gdb"
          "${workspaceFolder}/replace-with-binary")))
    (jmq/dap-register-template
     "Rust::Run"
     (jmq/dap-native-template
      "Rust::Run"
      "lldb-vscode"
      "${workspaceFolder}/target/debug/replace-with-binary"))

    (jmq/dap-register-template
     "C/C++::Run"
     (jmq/dap-native-template
      "C/C++::Run"
      "lldb-vscode"
      "${workspaceFolder}/replace-with-binary"))))

(provide 'jmq-debug)
