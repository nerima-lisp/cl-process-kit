(require :asdf)
(asdf:load-system "cl-process-kit")

(defun probe-once (use-posix-spawn thread-count iterations)
  (let ((start (get-internal-real-time))
        (threads
          (loop repeat thread-count
                collect
                (sb-thread:make-thread
                 (lambda ()
                   (loop repeat iterations
                         do (let ((process
                                    (process-kit:spawn "/bin/sh" (list "-c" "sleep 0.01")
                                                        :use-posix-spawn use-posix-spawn)))
                              (process-kit:process-wait process))))))))
    (dolist (thread threads)
      (sb-thread:join-thread thread))
    (/ (- (get-internal-real-time) start)
       internal-time-units-per-second)))

(let* ((thread-count 8)
       (iterations 20)
       (fork-seconds (probe-once nil thread-count iterations))
       (posix-seconds (probe-once t thread-count iterations)))
  (format t "fork (:use-posix-spawn nil): ~,3F s~%" fork-seconds)
  (format t "posix_spawn (:use-posix-spawn t): ~,3F s~%" posix-seconds)
  (format t "ratio posix_spawn/fork: ~,3F~%" (/ posix-seconds fork-seconds)))
