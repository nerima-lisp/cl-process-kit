(defpackage #:process-kit/pty
  (:documentation
   "Running a program attached to a pseudo-terminal rather than to pipes. A
child that inspects isatty(3) behaves differently under the two, so anything
whose output depends on being on a terminal — colour, progress bars, a shell's
interactive prompt — has to be driven from here. Optional: this package belongs
to the cl-process-kit/pty system, which links native/pty.c and depends on
cl-tty-kit.")
  (:use #:cl)
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
   #:pty-try-wait
   #:pty-alive-p
   #:pty-wait
   #:pty-process-result))
