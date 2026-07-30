;;;; src/package-pty.lisp
;;;;
;;;; Not folded into src/package.lisp, which CODING_STANDARD.md otherwise
;;;; makes the single home for defpackage forms. PROCESS-KIT/PTY belongs to
;;;; the optional cl-process-kit/pty system: that system is the only one that
;;;; links native/pty.c and depends on cl-tty-kit, and a plain
;;;; (asdf:load-system "cl-process-kit") must not define a package whose
;;;; symbols have no code behind them. The manifest therefore stays beside the
;;;; system it declares, under the package-<subsystem>.lisp name.

(defpackage #:process-kit/pty
  (:documentation
   "Running a program attached to a pseudo-terminal rather than to pipes. A
child that inspects isatty(3) behaves differently under the two, so anything
whose output depends on being on a terminal — colour, progress bars, a shell's
interactive prompt — has to be driven from here. Optional: this package belongs
to the cl-process-kit/pty system, which links native/pty.c and depends on
cl-tty-kit.")
  (:use #:cl)
  ;; Kept verbatim from the previous one-line manifest. Nothing this package
  ;; inherits binds PROCESS-PTY today -- CL does not define it and it is not
  ;; among the PROCESS-KIT symbols imported below -- so the form is inert; it
  ;; is retained because dropping it would change the package's
  ;; shadowing-symbols list, which is a separate decision from reformatting.
  (:shadow #:process-pty)
  (:import-from #:process-kit
                #:command-spec
                #:command-p
                #:command-program
                #:command-arguments
                #:command-search
                #:command-directory
                #:command-result-type
                #:command-external-format
                #:cancellation-requested-p
                #:make-process-result)
  (:export
   ;; session lifecycle
   #:pty-process
   #:spawn-pty
   #:process-pty
   #:pty-process-pid
   #:pty-close
   #:pty-cancel
   #:call-with-pty-process
   #:with-pty-process

   ;; byte and character transfer
   #:pty-read-octets
   #:pty-write-octets
   #:pty-read-string
   #:pty-write-string
   #:pty-send-eof

   ;; terminal and job control
   #:pty-resize
   #:pty-foreground-pgid
   #:pty-signal-foreground

   ;; completion
   #:pty-wait
   #:pty-process-result))
