;;;; src/package.lisp

(defpackage #:process-kit
  (:use #:cl)
  (:export
   #:process-result
   #:process-result-exit-code
   #:process-result-stdout
   #:process-result-stderr
   #:process-result-timed-out-p
   #:process-result-signal
   #:process-timeout-error
   #:process-timeout-error-command
   #:process-timeout-error-args
   #:process-timeout-error-timeout-seconds
   #:run
   #:spawn
   #:process-alive-p
   #:process-wait
   #:process-terminate
   #:process-kill))
