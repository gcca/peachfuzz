#!/usr/bin/env sbcl --script

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(ql:quickload :unix-opts :silent t)
(ql:quickload :sqlite :silent t)
(ql:quickload :cffi :silent t)

(cffi:define-foreign-library libargon2
  (:darwin (:or "libargon2.dylib"
                "/opt/homebrew/lib/libargon2.dylib"
                "/usr/local/lib/libargon2.dylib"
                "../urmom/build/libargon2.dylib"))
  (:unix (:or "libargon2.so"
              "/usr/lib/libargon2.so"
              "/usr/local/lib/libargon2.so"
              "../urmom/build/libargon2.so")))
(cffi:use-foreign-library libargon2)

(defconstant +argon2-ok+ 0)
(defconstant +argon2-version-13+ #x13)
(defparameter *db-path* "data/peachfuzz.db")
(defparameter *salt-len* 16)
(defparameter *hash-len* 32)

(cffi:defcstruct argon2-context
  (out :pointer) (outlen :uint32)
  (pwd :pointer) (pwdlen :uint32)
  (salt :pointer) (saltlen :uint32)
  (secret :pointer) (secretlen :uint32)
  (ad :pointer) (adlen :uint32)
  (t-cost :uint32) (m-cost :uint32)
  (lanes :uint32) (threads :uint32)
  (version :uint32)
  (allocate-cbk :pointer) (free-cbk :pointer)
  (flags :uint32))

(cffi:defcfun ("argon2id_ctx" %argon2id-ctx) :int (context :pointer))
(cffi:defcfun ("argon2_error_message" %argon2-error-message) :string (code :int))

(opts:define-opts
  (:name :help
         :description "Print this help text"
         :short #\h
         :long "help")
  (:name :username
         :description "Username whose password to change"
         :short #\u
         :long "username"
         :arg-parser #'identity
         :required t)
  (:name :password
         :description "New plaintext password"
         :short #\p
         :long "password"
         :arg-parser #'identity
         :required t))

(defun usage ()
  (opts:describe :prefix "Change an existing peachfuzz user's password (Argon2id, matches securing.zig)"
                 :usage-of "peachfuzz-change_user_password.lisp"))

(defun fill-random (ptr len)
  (with-open-file (in "/dev/urandom" :element-type '(unsigned-byte 8))
    (dotimes (i len) (setf (cffi:mem-aref ptr :uint8 i) (read-byte in)))))

(defun bytes->foreign (ptr vec)
  (dotimes (i (length vec)) (setf (cffi:mem-aref ptr :uint8 i) (aref vec i))))

(defun hash-password (username password)
  "Return a 48-byte (16 salt || 32 raw Argon2id hash) vector for securing.zig."
  (let ((pwd (sb-ext:string-to-octets password :external-format :utf-8))
        (ad (sb-ext:string-to-octets username :external-format :utf-8))
        (blob (make-array (+ *salt-len* *hash-len*) :element-type '(unsigned-byte 8))))
    (cffi:with-foreign-objects ((ctx '(:struct argon2-context))
                                (outp :uint8 *hash-len*)
                                (pwdp :uint8 (max 1 (length pwd)))
                                (adp :uint8 (max 1 (length ad)))
                                (saltp :uint8 *salt-len*))
      (fill-random saltp *salt-len*)
      (bytes->foreign pwdp pwd)
      (bytes->foreign adp ad)
      (macrolet ((cs (name) `(cffi:foreign-slot-value ctx '(:struct argon2-context) ',name)))
        (setf (cs out) outp (cs outlen) *hash-len*
              (cs pwd) pwdp (cs pwdlen) (length pwd)
              (cs salt) saltp (cs saltlen) *salt-len*
              (cs secret) (cffi:null-pointer) (cs secretlen) 0
              (cs ad) adp (cs adlen) (length ad)
              (cs t-cost) 3 (cs m-cost) 65536
              (cs lanes) 1 (cs threads) 1
              (cs version) +argon2-version-13+
              (cs allocate-cbk) (cffi:null-pointer) (cs free-cbk) (cffi:null-pointer)
              (cs flags) 0))
      (let ((rc (%argon2id-ctx ctx)))
        (unless (= rc +argon2-ok+)
          (error "argon2id failed: ~a" (%argon2-error-message rc)))
        (dotimes (i *salt-len*) (setf (aref blob i) (cffi:mem-aref saltp :uint8 i)))
        (dotimes (i *hash-len*) (setf (aref blob (+ *salt-len* i)) (cffi:mem-aref outp :uint8 i)))
        blob))))

(defun main ()
  (when (intersection '("-h" "--help") (opts:argv) :test #'string=)
    (usage)
    (opts:exit 0))
  (multiple-value-bind (options free-args)
      (handler-case (opts:get-opts)
        (error (c)
          (format *error-output* "Error: ~a~%" c)
          (usage)
          (opts:exit 1)))
    (declare (ignore free-args))
    (let ((username (getf options :username))
          (password (getf options :password)))
      (unless (probe-file *db-path*)
        (format *error-output* "Error: ~a not found (run from the peachfuzz repo root).~%" *db-path*)
        (opts:exit 1))
      (sqlite:with-open-database (db *db-path*)
        (when (zerop (sqlite:execute-single db "SELECT count(*) FROM auth_user WHERE username = ?" username))
          (format *error-output* "Error: no such user: ~a~%" username)
          (opts:exit 1))
        (sqlite:execute-non-query db "UPDATE auth_user SET password = ? WHERE username = ?"
                                  (hash-password username password) username)
        (format t "Password updated for user ~a.~%" username)))))

(main)
