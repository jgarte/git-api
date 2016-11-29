;;;; wrapper.lisp
;;
;; This package reads the compressed entry from the pack file
;;
(defpackage #:git-api.zlib.wrapper
  (:use #:cl #:alexandria #:git-api.utils #:static-vectors #:git-api.zlib.cffi)
  (:export *try-use-temporary-output-buffer*
   uncompress-stream
   uncompress-git-file))

(in-package #:git-api.zlib.wrapper)


(defparameter *try-use-temporary-output-buffer* t
  "When set to T the functions will use intermediate buffers to
unpack and return the data to avoid excessive memory allocations.
However, then the applying deltas recursive procedures in place,
the result output buffer should not be preallocated since it
will be merged with itself. So for deltas processing in pack files
this variable should be set to NIL")

(defparameter +buffer-size+ 8192
  "The size of the intermediate buffer")

(defparameter *temporary-read-buffer* (make-array +buffer-size+
                                                  :element-type '(unsigned-byte 8)
                                                  :fill-pointer t)
  "Static read buffer used to read small amounts of data from the stream")


(defparameter *temporary-output-buffer* (make-array +buffer-size+
                                                    :element-type '(unsigned-byte 8)
                                                    :fill-pointer +buffer-size+)
  "Static output buffer used containing uncompressed data. This buffer will
be returned if the uncompressed data size is less than +buffer-size+ and
if the variable *try-use-temporary-output-buffer* is T")  


(defparameter *temporary-static-read-buffer* (make-static-vector +buffer-size+)
  "Static read buffer used to read small amounts of data from the stream.
This buffer is used with CFFI version of zlib")
  

(defparameter *temporary-static-output-buffer* (make-static-vector +buffer-size+)
  "Static output buffer used containing uncompressed data. This buffer will
be returned if the uncompressed data size is less than +buffer-size+ and
if the variable *try-use-temporary-output-buffer* is T.
This buffer is used with CFFI version of zlib")  
  

(defvar *uncompressed-size-ptr* (cffi:foreign-alloc :unsigned-long)
  "A pointer to the uncompressed size used by CFFI zlib uncompress function")

(declaim (inline dispatch))
(defun uncompress-stream (offset compressed-size uncompressed-size stream)
  ;; try to guess which version to use
  (cond
   ;; first try CFFI version as the fastest
   (git-api.zlib.cffi:*zlib-loaded*
    (uncompress-stream-cffi offset compressed-size uncompressed-size stream))
   ;; as a fallback solution try to use patched CL zlib
   ;; patched means it supports manually specified output buffer
   ((or (> zlib::+zlib-major-version+ 0)
        (> zlib::+zlib-minor-version+ 1))
    (uncompress-stream-patched-zlib offset compressed-size uncompressed-size stream))
   ;; ... and finally try to use default (unpatched) CL zlib
   (t
    (uncompress-stream-git-zlib offset compressed-size uncompressed-size stream))))


(defun uncompress-stream-git-zlib (offset compressed-size uncompressed-size stream)
  "Return the uncompressed data for pack-entry from the opened file stream.
This function uses the CL zlib library from https://gitlab.common-lisp.net/
This zlib library version doesn't allow to specify output buffer, hence
the *try-use-temporary-output-buffer* variable will have no effect - new
buffers allocated all the time"
  ;; move to position data-offset
  (file-position stream offset)
  ;; uncompress chunk 
  (zlib:uncompress
   ;; of size compressed-size
   (let ((object (make-array compressed-size
                             :element-type '(unsigned-byte 8)
                             :fill-pointer t)))
     (read-sequence object stream)
     object) :uncompressed-size uncompressed-size))


(defun uncompress-stream-patched-zlib (offset compressed-size uncompressed-size stream)
  "Return the uncompressed data for pack-entry from the opened file stream.
This function uses the CL zlib library from https://github.com/fourier/zlib
This zlib library version allows to specify output buffer, so the implementation
will take the variable *try-use-temporary-output-buffer* into consideration"
  ;; move to position data-offset
  (file-position stream offset)
  (let ((read-buffer
         (if (> compressed-size +buffer-size+)
             (make-array compressed-size
                         :element-type '(unsigned-byte 8)
                         :fill-pointer t)
             *temporary-read-buffer*))
        (output-buffer
         (if (and *try-use-temporary-output-buffer*
                  (<= uncompressed-size +buffer-size+))
             (progn
               (setf (fill-pointer *temporary-output-buffer*) 0)
               *temporary-output-buffer*)
             (make-array uncompressed-size 
                         :element-type '(unsigned-byte 8)
                         :fill-pointer 0))))
    ;; sanity check
    (assert (>= (array-total-size read-buffer) compressed-size))
    ;; read the data
    (read-sequence read-buffer stream :end compressed-size)
    ;; uncompress chunk
    (zlib:uncompress read-buffer :output-buffer output-buffer :start 0 :end compressed-size)))


(defun uncompress-stream-cffi (offset compressed-size uncompressed-size stream)
  "Return the uncompressed data for pack-entry from the opened file stream.
This function uses the C zlib library using CFFI. The implementation
will take the variable *try-use-temporary-output-buffer* into consideration"
  ;; move to position data-offset
  (file-position stream offset)
  (let ((input *temporary-static-read-buffer*)
        (output *temporary-static-output-buffer*)
        (output-buffer *temporary-static-output-buffer*))
    ;; set value of the pointer to size output buffer    
    (setf (cffi:mem-ref *uncompressed-size-ptr* :unsigned-long) uncompressed-size)
    (handler-case
        (progn
          ;; check if we requested to use temporary buffers
          (unless *try-use-temporary-output-buffer*
            (setf input (make-static-vector compressed-size)
                  output (make-static-vector uncompressed-size)
                  output-buffer (make-array uncompressed-size 
                                            :element-type '(unsigned-byte 8))))
          ;; check if size of input buffer suits
          (when (and *try-use-temporary-output-buffer* (> compressed-size +buffer-size+))
            (setf input (make-static-vector compressed-size)))
          ;; and check if size of output buffer suits 
          (when (and *try-use-temporary-output-buffer* (> uncompressed-size +buffer-size+))
            (setf output (make-static-vector uncompressed-size)
                  output-buffer (make-array uncompressed-size 
                                            :element-type '(unsigned-byte 8))))
          ;; read the data
          (read-sequence input stream :end compressed-size)
          ;; uncompress chunk
          (let* ((foreign-output (static-vector-pointer output))
                 (result
                  (git-api.zlib.cffi:uncompress
                   foreign-output
                   *uncompressed-size-ptr*
                   (static-vector-pointer input)
                   compressed-size)))
            ;; check for error
            (unless (= result 0)
              (error (format nil "zlib::uncompress returned ~d" result)))
            ;; if necessary convert data from C to LISP format
            (unless (eq output-buffer *temporary-static-output-buffer*)
              (loop for i from 0 below uncompressed-size
                    for val = (the (unsigned-byte 8) (cffi:mem-aref foreign-output :unsigned-char i))
                    do (setf (aref output-buffer i) val)))
            ;; if necessary remove foreign arrays
            (unless (eq input *temporary-static-read-buffer*)
              (free-static-vector input))
            (unless (eq output *temporary-static-output-buffer*)
              (free-static-vector output))
            ;; good, output buffer now contains the data
            output-buffer))
      (error (e)
        (progn
          ;; if necessary remove foreign arrays
          (unless (eq input *temporary-static-read-buffer*)
            (free-static-vector input))
          (unless (eq output *temporary-static-output-buffer*)
            (free-static-vector output))
          (error e))))))


(declaim (inline dispatch))
(defun uncompress-git-file (filename)
  (let ((binary (read-binary-file filename)))
    ;; try to guess which version to use
    (fixme "remove NOT as soon as cffi implementation is ready")
    (if (not git-api.zlib.cffi:*zlib-loaded*)
        ;; first try CFFI version as the fastest
        (uncompress-git-file-cffi binary)
        (uncompress-git-file-zlib binary))))



(defun uncompress-git-file-zlib (data)
  ;;          (with-open-file (stream filename :direction :input :element-type '(unsigned-byte 8))
  ;;                 (chipz:decompress nil 'chipz:zlib stream)))
  (zlib:uncompress data))
  

(defun uncompress-git-file-cffi (data)
  (let ((stream-size (cffi:foreign-type-size '(:struct z-stream))))
    ;; create a stream struct
    (cffi:with-foreign-object (strm '(:struct z-stream))
      ;; clear the stream struct
;      (foreign-funcall "memset" :pointer strm :int 0 :int stream-size)
;      (foreign-funcall "memset" :pointer strm :int 0 :int stream-size)
      ;; initalize values in struct
      (cffi:with-foreign-slots ((next-in avail-in next-out avail-out) strm (:struct z-stream))
        (setf next-in data
              avail-in (length data)
              next-out nil; buf
              avail-out uncompressed-size))
      ;; initialize the stream
      (inflate-init_ strm (zlib-version) stream-size)
      (inflate strm +z-finish+)
      (inflate-end strm))))
