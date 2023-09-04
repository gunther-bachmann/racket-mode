;;; racket-hash-lang.el -*- lexical-binding: t; -*-

;; Copyright (c) 2020-2023 by Greg Hendershott.
;; Portions Copyright (C) 1985-1986, 1999-2013 Free Software Foundation, Inc.

;; Author: Greg Hendershott
;; URL: https://github.com/greghendershott/racket-mode

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'seq)
(require 'racket-cmd)
(require 'racket-common)
(require 'racket-repl)

(defvar-local racket--hash-lang-id nil
  "Unique integer used to identify the back end hash-lang object.
Although it's tempting to use `buffer-file-name' for the ID, not
all buffers have files, especially `racket-repl-mode' buffers.
Although it's tempting to use `buffer-name', buffers can be
renamed. Although it's tempting to use the buffer object, we
can't serialize that.")
(defvar racket--hash-lang-next-id 0
  "Increment when we need a new id.")

(defvar-local racket--hash-lang-generation 1
  "Monotonic increasing value for hash-lang updates.

This is set to 1 when we hash-lang create, incremented every time
we do a hash-lang update, and then supplied for all other, query
hash-lang operations. That way the queries can block if necessary
until the back end has handled the update commands and also
re-tokenization has progressed sufficiently.")

(defvar-local racket--hash-lang-changed-vars nil
  "Original values when minor mode was enabled, to restore when disabled.")

(defvar racket-hash-lang-mode-map
  (racket--easy-keymap-define
   `(("RET"   ,#'racket-hash-lang-return)
     (")"     ,#'self-insert-command) ;not `racket-insert-closing'
     ("}"     ,#'self-insert-command) ;not `racket-insert-closing'
     ("]"     ,#'self-insert-command) ;not `racket-insert-closing'
     ("C-M-b" ,#'racket-hash-lang-backward)
     ("C-M-f" ,#'racket-hash-lang-forward)
     ("C-M-u" ,#'racket-hash-lang-up)
     ("C-M-d" ,#'racket-hash-lang-down))))

(defvar-local racket-hash-lang-mode-lighter " #lang")

(defvar-local racket--hash-lang-submit-predicate-p nil)

(defvar-local racket-hash-lang-module-language nil
  "The symbol for the module language, if any, else nil.")

(defvar racket-hash-lang-module-language-hook nil
  "Hook run when the module language changes.

Your hook function may do additional customization based on the
the variable `racket-hash-lang-module-language'.")

;;;###autoload
(define-minor-mode racket-hash-lang-mode
  "Use color-lexer, indent, and navigation supplied by a #lang.

Minor mode to modify the default behavior `racket-mode' and
`racket-repl-mode' buffers.

For `racket-mode' buffers, this needs to be enabled via
`racket-mode-hook'.

For `racket-repl-mode' buffers, this should not need to be
configured manually. Instead automatically turns itself on/off,
for each `racket-run', based on whether the associated
`racket-mode' buffer is using `racket-hash-lang-mode'.

For `racket-repl-mode' buffers, be aware that only input portions
of the buffer use coloring/indent/navigation from the hash-lang.
Output portions are treated as whitespace.

Runs the hook variable `racket-hash-lang-module-language-hook'
when the module language changes.

\\{racket-hash-lang-mode-map}
"
  :lighter racket-hash-lang-mode-lighter
  :keymap  racket-hash-lang-mode-map
  (with-silent-modifications
    (save-restriction
      (widen)
      (unless (memq major-mode '(racket-mode racket-repl-mode))
        (error "racket-hash-lang-mode only works with racket-mode and racket-repl-mode buffers"))
      (racket--hash-lang-remove-text-properties (point-min) (point-max))
      (remove-text-properties (point-min) (point-max) 'racket-here-string nil)
      (cond
       ;; Enable
       (racket-hash-lang-mode
        (setq-local racket--hash-lang-generation 1)
        (electric-indent-local-mode -1)
        (setq-local
         racket--hash-lang-changed-vars
         (racket--hash-lang-set/reset
          `((electric-indent-inhibit t)
            (blink-paren-function nil)
            (font-lock-defaults nil)
            (font-lock-fontify-region-function ,#'racket--hash-lang-font-lock-fontify-region)
            ((,#'set-syntax-table ,#'syntax-table) ,racket-mode-syntax-table)
            (syntax-propertize-function nil)
            (text-property-default-nonsticky ,(append
                                               (racket--hash-lang-text-prop-list #'cons t)
                                               text-property-default-nonsticky))
            (indent-line-function ,indent-line-function)
            (indent-region-function ,indent-region-function)
            (forward-sexp-function ,forward-sexp-function))))
        (add-hook 'comint-preoutput-filter-functions #'racket--hash-lang-repl-preoutput-filter-function t t)
        (add-hook 'after-change-functions #'racket--hash-lang-after-change-hook t t)
        (add-hook 'kill-buffer-hook #'racket--hash-lang-delete t t)
        (racket--hash-lang-create))
       ;; Disable
       (t
        (racket--hash-lang-delete)
        (racket--hash-lang-set/reset racket--hash-lang-changed-vars)
        (remove-hook 'comint-preoutput-filter-functions #'racket--hash-lang-repl-preoutput-filter-function t)
        (remove-hook 'after-change-functions #'racket--hash-lang-after-change-hook t)
        (remove-hook 'kill-buffer-hook #'racket--hash-lang-delete t)
        (electric-indent-local-mode 1)))
      (save-restriction
        (widen)
        (syntax-ppss-flush-cache (point-min)))))
  (font-lock-flush))

;; Upon enabling/disabling our minor mode, we need to set/reset many
;; variables. Make this less tedious and error-prone.
(defun racket--hash-lang-set/reset (specs)
  "Call with SPECS to initially set things.
Returns new specs to restore the original values. Each spec is
either (variable-symbol new-value) or ((setter-function
getter-function) new-value)."
  (mapcar (lambda (spec)
            (pcase spec
              (`((,setter ,getter) ,new-val)
               (let ((old-val (funcall getter)))
                 (funcall setter new-val)
                 `((,setter ,getter) ,old-val)))
              (`(,sym ,new-val)
               (let ((old-val (symbol-value sym)))
                 (make-local-variable sym) ;do equivalent of...
                 (set sym new-val)         ;..setq-local
                 `(,sym ,old-val)))))
          specs))

(defun racket--hash-lang-before-run-hook ()
  "Enable/disable `racket-hash-lang-mode' in the REPL to match `current-buffer'.

The idea here is that a run command happens from a `racket-mode'
edit buffer, so we can use that opportunity to set
`racket-repl-mode' to match the use of `racket-hash-lang-mode' or
not. Intended as a convenience so users needn't set a
`racket-repl-mode-hook' in addition to a `racket-mode-hook'."
  (let ((enable racket-hash-lang-mode))
    (with-racket-repl-buffer
      (unless (eq racket-hash-lang-mode enable)
        (racket-hash-lang-mode (if enable 1 -1))))))
(add-hook 'racket--repl-before-run-hook #'racket--hash-lang-before-run-hook)

(defun racket--hash-lang-create ()
  (setq-local racket--hash-lang-id
              (cl-incf racket--hash-lang-next-id))
  (racket--cmd/await
   nil
   `(hash-lang create
               ,racket--hash-lang-id
               ,(when (eq major-mode 'racket-repl-mode) racket--repl-session-id)
               ,(save-restriction
                  (widen)
                  (if (eq major-mode 'racket-repl-mode)
                      (racket--hash-lang-repl-buffer-string (point-min) (point-max))
                    (buffer-substring-no-properties (point-min) (point-max)))))))

(defun racket--hash-lang-delete ()
  (when racket--hash-lang-id
    (racket--cmd/async
     nil
     `(hash-lang delete ,racket--hash-lang-id))
    (setq racket--hash-lang-id nil)))


(defun racket--hash-lang-find-buffer (id)
  "Find the buffer whose local value for `racket--hash-lang-id' is ID."
  (cl-some (lambda (buf)
             (when (equal id (buffer-local-value 'racket--hash-lang-id buf))
               buf))
           (buffer-list)))

(defconst racket--hash-lang-plain-syntax-table
  (let ((st (make-syntax-table)))
    ;; Modify entries for characters for parens, strings, and
    ;; comments, setting them to word syntax instead. (For the these
    ;; raw syntax descriptor numbers, see Emacs Lisp Info: "Syntax
    ;; Table Internals".)
    (map-char-table (lambda (key value)
                      (when (memq (car value) '(4 5 7 10 11 12))
                        (aset st key '(2))))
                    st)
    st))

;;; Updates: Front end --> back end

(defun racket--hash-lang-after-change-hook (beg end len)
  ;;;(message "racket--hash-lang-after-change-hook %s %s %s" beg end len)
  ;; This might be called as frequently as once per single changed
  ;; character.
  (racket--cmd/async
   nil
   `(hash-lang update
               ,racket--hash-lang-id
               ,(cl-incf racket--hash-lang-generation)
               ,beg
               ,len
               ,(if (eq major-mode 'racket-repl-mode)
                    (racket--hash-lang-repl-buffer-string beg end)
                  (buffer-substring-no-properties beg end)))))

;;; Notifications: Front end <-- back end

(defun racket--hash-lang-on-notify (id params)
  (when-let (buf (racket--hash-lang-find-buffer id))
    (with-current-buffer buf
      (pcase params
        (`(lang . ,params)        (racket--hash-lang-on-new-lang params))
        (`(update ,gen ,beg ,end) (racket--hash-lang-on-changed-tokens gen beg end))))))

(defun racket--hash-lang-on-new-lang (plist)
  "We get this whenever any #lang supplied attributes have changed.

We do /not/ get notified when a new lang uses exactly the same
attributes as the old one. For example changing from #lang racket
to #lang racket/base will /not/ notify us, because none of the
lang's attributes that we care about have changed."
  ;;;(message "racket--hash-lang-on-new-lang %s" plist)
  (with-silent-modifications
    (save-restriction
      (widen)
      (racket--hash-lang-remove-text-properties (point-min) (point-max))
      (font-lock-flush (point-min) (point-max))
      ;; If the lang uses racket-grouping-position, i.e. it uses
      ;; s-expressions, then use racket-mode-syntax-table. That way
      ;; other Emacs features and packages are more likely to work.
      ;; Otherwise, assume nothing about the lang and set a "plain"
      ;; syntax table where no characters are assumed to delimit
      ;; parens, comments, or strings.
      (set-syntax-table (if (plist-get plist 'racket-grouping)
                            racket-mode-syntax-table
                          racket--hash-lang-plain-syntax-table))
      ;; Similarly for `forward-sexp-function'. The
      ;; drracket:grouping-position protocol doesn't support a nuance
      ;; where a `forward-sexp-function' should signal an exception
      ;; containing failure positions. Although this is N/A for simple
      ;; forward/backward scenarios (such as when `prog-indent-sexp'
      ;; uses `forward-sexp' to set a region), it matters when things
      ;; like `up-list' use `forward-sexp'.
      (setq forward-sexp-function (unless (plist-get plist 'racket-grouping)
                                    #'racket-hash-lang-forward-sexp))
      (syntax-ppss-flush-cache (point-min))
      (setq-local indent-line-function
                  #'racket-hash-lang-indent-line-function)
      (setq-local indent-region-function
                  (when (plist-get plist 'range-indenter)
                    #'racket-hash-lang-indent-region-function))
      (setq-local racket--hash-lang-submit-predicate-p
                  (plist-get plist 'submit-predicate))
      (setq-local racket-hash-lang-mode-lighter
                  (concat " #lang"
                          (when (plist-get plist 'racket-grouping) "()")
                          (when (plist-get plist 'range-indenter) "⇉")))
      (pcase-let ((`(,start ,continue ,end ,padding) (plist-get plist 'comments)))
        (setq-local comment-start      start)
        (setq-local comment-continue   continue)
        (setq-local comment-end        end)
        (setq-local comment-padding    padding)
        (setq-local comment-use-syntax nil)
        ;; Use `comment-normalize-vars' to recalc the skip regexps.
        (setq-local comment-start-skip nil)
        (setq-local comment-end-skip   nil)
        (comment-normalize-vars))
      ;; Finally run user's module language hooks.
      (progn
        (setq racket-hash-lang-module-language (plist-get plist 'module-language))
        (run-hooks 'racket-hash-lang-module-language-hook)))))

(defun racket--hash-lang-on-changed-tokens (_gen beg end)
  "The back end has processed a change that resulted in new tokens.

All we do here is mark the span as not fontified, then let
jit-lock do its thing if/when this span ever becomes visible."
  ;;;(message "racket--hash-lang-on-changed-tokens %s %s %s" _gen beg end)
  (font-lock-flush beg end))

;;; Fontification

(defun racket--hash-lang-font-lock-fontify-region (beg end &optional _loudly)
  "Our value for the variable `font-lock-fontify-region-function'.

We ask the back end for tokens, and handle its response
asynchronously in `racket--hash-lang-on-tokens' which does the
actual application of faces and syntax. It wouldn't be
appropriate to wait for a response while being called from Emacs
C redisplay engine, as is the case with `jit-lock-mode'."
  ;;;(message "racket--hash-lang-font-lock-fontify-region %s %s" beg end)
  (racket--cmd/async
   nil
   `(hash-lang get-tokens
               ,racket--hash-lang-id
               ,racket--hash-lang-generation
               ,beg
               ,end)
   #'racket--hash-lang-on-tokens)
  `(jit-lock-bounds ,beg . ,end))

(defun racket--hash-lang-on-tokens (tokens)
  (save-restriction
    (widen)
    (with-silent-modifications
      (cl-flet ((put-face (beg end face) (put-text-property beg end 'face face))
                (put-stx  (beg end stx)  (put-text-property beg end 'syntax-table stx)))
        (dolist (token tokens)
          (pcase-let ((`(,beg ,end ,kinds) token))
            (setq beg (max (point-min) beg))
            (setq end (min end (point-max)))
            (racket--hash-lang-remove-text-properties beg end)
            ;; Add 'racket-token just for me to examine results using
            ;; `describe-char'; use vector b/c `describe-property-list'
            ;; assumes lists of symbols are "widgets".
            (put-text-property beg end 'racket-token (apply #'vector kinds))
            (dolist (kind kinds)
              (pcase kind
                ('comment
                 (put-face beg end 'font-lock-comment-face)
                 ;; When the start/end match comment-start/end, then
                 ;; give those spans comment start/end syntax. (This
                 ;; helps with e.g. `comment-region' and
                 ;; `uncomment-region'. Give the remainder generic
                 ;; comment syntax.
                 (let ((comment-start-end (+ beg (length comment-start))))
                   (when (and (<= comment-start-end (point-max))
                              (string-equal comment-start
                                            (buffer-substring beg comment-start-end)))
                     (put-stx beg comment-start-end '(11))
                     (setq beg comment-start-end)))
                 (let* ((comment-end (if (equal comment-end "") "\n" comment-end))
                        (comment-end-start (- end (length comment-end))))
                   (when (and (<= comment-end-start (point-max))
                              (string-equal comment-end
                                            (buffer-substring comment-end-start end)))
                     (put-stx comment-end-start end '(12))
                     (setq end comment-end-start)))
                 (put-stx beg end '(14))) ;generic comment
                ('sexp-comment ;just the "#;" prefix not following sexp
                 (put-stx beg end '(14)) ;generic comment
                 (put-face beg end 'font-lock-comment-face))
                ;; Note: This relies on the back end supplying `kinds`
                ;; with sexp-comment-body last, so that we can modify
                ;; the face property already set by the previous
                ;; kind(s).
                ('sexp-comment-body
                 (put-face beg end (racket--sexp-comment-face
                                    (get-text-property beg 'face))))
                ('parenthesis (when (facep 'parenthesis)
                                (put-face beg end 'parenthesis)))
                ('string (put-face beg end 'font-lock-string-face))
                ('text (put-stx beg end racket--hash-lang-plain-syntax-table))
                ('constant (put-face beg end 'font-lock-constant-face))
                ('error (put-face beg end 'error))
                ('symbol (put-face beg end 'racket-hash-lang-symbol-face))
                ('keyword (put-face beg end 'font-lock-keyword-face))
                ('hash-colon-keyword (put-face beg end 'racket-keyword-argument-face))
                ('other (put-face beg end 'font-lock-doc-face))
                ('at (put-face beg end 'racket-hash-lang-at-face))
                ('operator (put-face beg end 'racket-hash-lang-operator-face))
                ('white-space nil)))))))))

(defconst racket--hash-lang-text-properties
  '(face syntax-table racket-token)
  "The text properties we use.")

(defun racket--hash-lang-text-prop-list (f val)
  (mapcar (lambda (prop-sym) (funcall f prop-sym val))
          racket--hash-lang-text-properties))

(defun racket--hash-lang-remove-text-properties (beg end)
  "Remove `racket--hash-lang-text-properties' from region BEG..END."
  (remove-text-properties beg end
                          (apply #'append
                                 (racket--hash-lang-text-prop-list #'list nil))))


;;; Unique to racket-repl-mode

(defun racket--hash-lang-repl-preoutput-filter-function (str)
  "Give output a field property.

Our `racket--hash-lang-after-change-hook' and
`racket--hash-lang-repl-buffer-string' functions need to see
field properties. Alas `comint-mode' does an `insert' before
applying any field properties. Fix: Apply them earlier, here.

Note: This might be unreliable unless it is the last value in
the `comint-preoutput-filter-functions' list."
  (propertize str 'field 'output))

(defun racket--hash-lang-repl-buffer-string (beg end)
  "Like `buffer-substring-no-properties' but non-input is whitespace.

A REPL buffer is a \"hopeless\" mix of user input, which we want
a hash-lang to color and indent, as well as user program output
and REPL prompts, which we want to ignore. This function replaces
output with whitespace --- mostly spaces, but preserves newlines
for the sake of indent alignment. The only portions not affected
are input --- text that the user has typed or yanked in the REPL
buffer."
  (save-restriction
    (widen)
    (let ((pos beg)
          (result-str ""))
      (while (< pos end)
        ;; Handle a chunk sharing same field property value.
        (let* ((chunk-end (min (or (next-single-property-change pos 'field)
                                   (point-max))
                               end))
               (chunk-str (buffer-substring-no-properties pos chunk-end)))
          ;; Unless input, replace all non-newline chars with spaces.
          (unless (null (get-text-property pos 'field))
            (let ((i 0)
                  (len (- chunk-end pos)))
              (while (< i len)
                (unless (eq ?\n (aref chunk-str i))
                  (aset chunk-str i 32))
                (setq i (1+ i)))))
          (setq result-str (concat result-str chunk-str))
          (setq pos chunk-end)))
      result-str)))

;;; Indent

(defun racket-hash-lang-indent-line-function ()
  "Use drracket:indentation supplied by the lang.

If a lang doesn't supply this, or if the supplied function ever
returns false, then we always use the standard s-expression
indenter from syntax-color/racket-indentation.

We never use `racket-indent-line' from traditional
`racket-mode'."
  (let* ((bol (save-excursion (beginning-of-line) (point)))
         (pos (- (point-max) (point)))
         (col (racket--cmd/await        ; await = :(
               nil
               `(hash-lang indent-amount
                           ,racket--hash-lang-id
                           ,racket--hash-lang-generation
                           ,(point)))))
    (goto-char bol)
    (skip-chars-forward " \t") ;;TODO: Is this reliable for all langs?
    (unless (= col (current-column))
      (delete-region bol (point))
      (indent-to col))
    ;; When point is within the leading whitespace, move it past the
    ;; new indentation whitespace. Otherwise preserve its position
    ;; relative to the original text.
    (when (< (point) (- (point-max) pos))
      (goto-char (- (point-max) pos)))))

(defun racket-hash-lang-indent-region-function (from upto)
  "Maybe use #lang drracket:range-indentation, else plain `indent-region'."
  (pcase (racket--cmd/await   ; await = :(
                    nil
                    `(hash-lang indent-region-amounts
                                ,racket--hash-lang-id
                                ,racket--hash-lang-generation
                                ,from
                                ,upto))
    ('false (let ((indent-region-function nil))
              (indent-region from upto)))
    (`() nil)
    (results
     (save-excursion
       (goto-char from)
        ;; drracket:range-indent docs say `results` could have more
        ;; elements than lines in from..upto, and we should ignore
        ;; extras. Handle that. (Although it could also have fewer, we
        ;; need no special handling for that here.)
        (let ((results (seq-take results (count-lines from upto))))
          (dolist (result results)
            (pcase-let ((`(,delete-amount ,insert-string) result))
              (beginning-of-line)
              (when (< 0 delete-amount) (delete-char delete-amount))
              (unless (equal "" insert-string) (insert insert-string))
              (end-of-line 2))))))))

;; Motion

(defun racket-hash-lang-move (direction &optional count)
  (let ((count (or count 1)))
    (pcase (racket--cmd/await       ; await = :(
            nil
            `(hash-lang grouping
                        ,racket--hash-lang-id
                        ,racket--hash-lang-generation
                        ,(point)
                        ,direction
                        0
                        ,count))
      ((and (pred numberp) pos)
       (goto-char pos))
      (_ (user-error "Cannot move %s%s" direction (if (memq count '(-1 0 1))
                                                      ""
                                                    (format " %s times" count)))))))

(defun racket-hash-lang-backward (&optional count)
  "Like `backward-sexp' but uses #lang supplied navigation."
  (interactive "^p")
  (racket-hash-lang-move 'backward count))

(defun racket-hash-lang-forward (&optional count)
  "Like `forward-sexp' but uses #lang supplied navigation."
  (interactive "^p")
  (racket-hash-lang-move 'forward count))

(defun racket-hash-lang-up (&optional count)
  "Like `backward-up-list' but uses #lang supplied navigation."
  (interactive "^p")
  (racket-hash-lang-move 'up count))

(defun racket-hash-lang-down (&optional count)
  "Like `down-list' but uses #lang supplied navigation."
  (interactive "^p")
  (racket-hash-lang-move 'down count))

(defun racket-hash-lang-forward-sexp (&optional arg)
  "A value for the variable `forward-sexp-function'.

Caveat: This uses drracket:grouping-position, which doesn't have
a concept of signaling the position of a \"barrier\" that
prevented navigation forward/backward. Some users of
`forward-sexp' depend on that signal, for example `up-list'.
However other users don't need that, so we supply this
`forward-sexp-function' as \"better than nothing\"."
  (let* ((arg (or arg 1))
         (dir (if (< arg 0) 'backward 'forward))
         (cnt (abs arg)))
    (racket-hash-lang-move dir cnt)))

(defun racket-hash-lang-return (&optional prefix)
  "A command to bind to RET a.k.a. C-m.

In `racket-mode' buffers: `newline-and-indent'.

In `racket-repl-mode' buffers: `racket-repl-submit' -- unless the
#lang supplies a drracket:submit-predicate and that says there is
not a complete expression, in which case `newline-and-indent'."
  (interactive "P")
  (if (and (eq major-mode 'racket-repl-mode)
           (or (not racket--hash-lang-submit-predicate-p)
               (racket--cmd/await nil
                                  `(hash-lang
                                    submit-predicate
                                    ,racket--hash-lang-id
                                    ,(substring-no-properties
                                      (funcall comint-get-old-input))
                                    t))))
      (racket-repl-submit prefix)
    (newline-and-indent)))

(provide 'racket-hash-lang)

;; racket-hash-lang.el ends here
