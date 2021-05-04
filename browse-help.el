;;; browse-help.el --- Context-sensitive help via a WWW browser for GNU Emacs

;; Revision: 0.9 Date: 2000/01/04 18:20:00

;; Author: Tim Anderson <tma@netspace.net.au>
;; Maintainer: Tim Anderson
;; Keywords: help browser

;; Copyright (C) 1999,2000 Tim Anderson

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

;;; Commentary:

;; This package provides support for context-sensitive help within Emacs.
;; It parses user supplied help files to build up an index of topics and
;; their corresponding URLs. When a topic is looked up, its help
;; is displayed to a browser via the browse-url package.

;;
;; Current functionality includes:
;; . browsing help for the current word
;; . browsing help for the current region
;; . interactive searches, with completion
;;

;; Usage:
;;
;; To use this package, add the following to your .emacs file:
;;
;; (require 'browse-help)
;;
;; Now customize `browse-help-files' located in the Help->Browse Help
;; customization group. This associates help files with their appropriate
;; Emacs modes.
;;
;; Help files may be:
;; . HTML documents
;;   The HTML parser will parse entries of the form:
;;      <a href=URL>TOPIC</a>
;; . Index files
;;   Each line must contain entries of the form:
;;      TOPIC<tab>URL
;;
;; To use the help, set up appropriate key bindings for:
;; . `browse-help-on-current-word'
;;   This searches help associated with the current mode for the current
;;   word. If there is a single match, the associated URL will be displayed in
;;   a browser. If there are multiple matches, they will be displayed to a
;;   Browse Help buffer; from here the appropriate topic can be selected with
;;   the mouse.
;;   The default key binding is C-c C-w.
;;
;; . `browse-help-on-current-region'
;;   This provides the same basic functionality as
;;   `browse-help-on-current-word' except that the search is done using the
;;   current selected region.
;;   The default key binding is C-c C-r.
;;
;; . `browse-help-search'
;;   This performs an interactive search (with completion) of help
;;   associated with the current mode.
;;   The default key binding is C-c C-f.
;;
;; . `browse-help-display-manuals-for-mode'
;;   This displays all help associated with a particular mode.
;;   The default key binding is C-c C-m.
;;
;; You can customize the key bindings via `browse-help-key-bindings'.
;;
;; Other relevant functions:
;; . `browse-help-display-manual'
;;   Display a single help manual.
;;
;; . `browse-help-save-manual'
;;   Saves manual as an index file, parseable by `browse-help-parse-index'.

;;; Code:

(require 'browse-url)
(require 'cl)
(require 'cus-edit)

;; --------------------------------------------------------------
;; Customization support
;; --------------------------------------------------------------

(defgroup browse-help nil
  "Customization support for Browse Help."
  :group 'help
  :prefix "browse-help-")

(setq browse-help-init-after-load nil)
; when non-nil, delay call to browse-help-init to ensure
; that browse-help is fully loaded.

(defcustom browse-help-files nil
  "*Specifies help files for Browse Help.
The value of this variable is a list of the form:
\t((HELP-FILES . MODES)...)

Each entry associates a set of help files with the Emacs modes
that they should provide context-sensitive help for.

. HELP-FILES is a list of the form:
\t((FILENAME . URL-PREFIX)...)
  . FILENAME specifies a help file to parse.
  . URL-PREFIX specifies a prefix to fully qualify relative URLs.
    If nil (the default), the path of FILENAME will be used.
    You only need to set this if the help file contains
    relative URLs that are:
    . on a different host
    . in a different location relative to the help file
. MODES is a list of mode names for which the help files apply.
  If nil, the help files will be available in all modes."
  :type '(repeat
    (cons :tag "Context Sensitive Help"
    (repeat :tag "Help files"
      (cons :tag "Entry"
         (file :tag "File")
         (choice :tag "URL Prefix"
           (const :tag "Default" nil)
           (string :tag "Prefix"))))
    (choice :tag "Modes for which this help applies"
      (const :tag "All modes" nil)
      (repeat :tag "Modes" (string :tag "Name")))))
  :group 'browse-help
  :set '(lambda (sym value)
    (if (and (boundp 'browse-help-files)
       (equal browse-help-files value))
     () ; Hmm - doesn't at all do what its supposed to.
        ; Should only be invoked if the definitions are different
        ; Does defcustom declare a local browse-help-files? TODO
   (set-default sym value))
   (if (featurep 'browse-help)
    ; only call init if browse-help has been loaded...
    (browse-help-init)
     ; else delay init until it has
     (setq browse-help-init-after-load t))))

; Lifted from "jde.el"
(defcustom browse-help-key-bindings
  (list (cons "\C-c\C-w" 'browse-help-on-current-word)
  (cons "\C-c\C-r" 'browse-help-on-current-region)
  (cons "\C-c\C-f" 'browse-help-search)
  (cons "\C-c\C-m" 'browse-help-display-manuals-for-mode))
  "*Specifies key bindings for Browse Help.
The value of this variable is an association list. The car of
each element specifies a key sequence. The cdr of each element
specifies an interactive command that the key sequence executes.
To enter a key with a modifier, type C-q followed by the desired
modified keystroke. For example, to enter C-s (Control s) as the
key to be bound, type C-q C-s in the key field in the customization
buffer."
  :group 'browse-help
  :type '(repeat
    (cons :tag "Key binding"
    (sexp :tag "Key")
    (function :tag "Command")))
  :set '(lambda (sym val)
    (mapc (lambda (binding)
      ; bit nasty because it trashes global bindings.
      ; TODO
      (global-set-key (car binding) (cdr binding)))
    val)
    (set-default sym val)))

(defcustom browse-help-show-url-flag t
  "*Non-nil specifies to show the URL of the highlighted topic.
This is only active when in a *Browse Help* buffer. The URL is displayed
to the minibuffer."
  :tag "Show URL"
  :group 'browse-help
  :type 'boolean
  :set '(lambda (sym val)
    (set-default sym val)
    (if (featurep 'browse-help)
     (browse-help-mode-setup-show-info))))

(defcustom browse-help-show-manual-flag nil
  "*Non-nil specifies to show the manual name of the highlighted topic.
This is only active when in a *Browse Help* buffer. The manual name is
displayed to the minibuffer."
  :tag "Show Manual"
  :group 'browse-help
  :type 'boolean
  :set '(lambda (sym val)
    (set-default sym val)
    (if (featurep 'browse-help)
     (browse-help-mode-setup-show-info))))

(defcustom browse-help-parsers
  (list (cons 'browse-help-parse-html ".\\(html\\|htm\\)$")
  (cons 'browse-help-parse-index ".*"))
  "*Specifies parsers for Browse Help.
The parsers are used to generate manuals from the files listed in
`browse-help-files'.
The value of this variable is an association list. The car of
each element specifies a parser function, used to parse a file.
The cdr of each element specifies a regular expression, used to determine
the types of files that the parser can be used on.
The first regular expression that matches a manual's file name is used
to select the parser function.
NOTE: the regular expression is case-insensitive."
  :type '(repeat
    (cons :tag "Parser"
    (function :tag "Function")
    (regexp :tag "For all files matching")))
  :group 'browse-help)

(defconst browse-help-browser-function browse-url-browser-function
  "Function to display help to a browser.")

(defconst browse-help-buffer-name "*Browse Help*" "Name of topic list buffer.")

(defvar browse-help-mode-display-info-flag nil
  "Non-nil means display info on highlighted topic to minibuffer.")

;; --------------------------------------------------------------
;; Browse help on the current context
;; --------------------------------------------------------------

(defun browse-help-on-current-word ()
  "Browse help for the current word."
  (interactive)
  (browse-help-debug "browse-help-on-current-word: %s" (current-word))
  (let ((matches
  (browse-help-search-manuals-for-mode mode-name (current-word))))
    (browse-help-debug "browse-help-on-current-word: matches = %s" matches)
    (if matches
  (if (> (length matches) 1)
   (browse-help-mode-display-topics matches)
    (browse-help-launch-browser (nth 2 (car matches))))
      (browse-help-message "No help on %s" (current-word)))))

(defun browse-help-on-current-region ()
  "Browse help for the current selected region."
  (interactive)
  (let* ((region (buffer-substring (region-beginning) (region-end)))
  (matches (browse-help-search-manuals-for-mode mode-name region)))
    (browse-help-debug "browse-help-on-current-region: %s" region)
    (if matches
  (if (> (length matches) 1)
   (browse-help-mode-display-topics matches)
    (browse-help-launch-browser (nth 2 (car matches))))
      (browse-help-message "No help on %s" region))))

;; --------------------------------------------------------------
;; Interactive search support
;; --------------------------------------------------------------

(setq browse-help-all-topics nil)   ; all topics for current mode
(setq browse-help-last-topic nil)   ; last topic for completion
(setq browse-help-last-matches nil) ; matches for browse-help-last-topic
(setq browse-help-current-mode nil)
(setq browse-help-completed-topic nil)

(defun browse-help-search ()
  "Search manuals associated with the current mode."
  (interactive)
  (setq browse-help-all-topics nil)
  (setq browse-help-completed-topic nil)
  (setq browse-help-current-mode mode-name)
  (setq browse-help-last-matches nil)
  (setq browse-help-last-topic nil)
  (setq browse-help-complete-map (copy-keymap minibuffer-local-map))
  (define-key browse-help-complete-map "\t" 'browse-help-complete)
  (define-key browse-help-complete-map "\r" 'browse-help-exit-complete)
  (define-key browse-help-complete-map "\n" 'browse-help-exit-complete)
  (read-from-minibuffer (format "Browse %s topic: " mode-name)
   nil browse-help-complete-map)
  (if browse-help-completed-topic
      (browse-help-launch-browser (nth 2 browse-help-completed-topic))))

(defun browse-help-exit-complete ()
  (interactive)
  (let ((topic (buffer-substring (point-min) (point-max))))
    (if (not (equal topic ""))
 (if (not (equal topic (car browse-help-completed-topic)))
     (browse-help-tmp-message " [Not complete]")
   (exit-minibuffer))
      (setq browse-help-completed-topic nil)
      (exit-minibuffer))))

(defun browse-help-complete ()
  (interactive)
  (let ((topic (buffer-substring (point-min) (point-max))))
    (browse-help-debug "browse-help-complete: %s" topic)
    (if (not browse-help-all-topics)
  (progn
    (browse-help-message "Building topic list for %s..."
          browse-help-current-mode)
    (setq browse-help-all-topics (browse-help-get-topics
          (browse-help-get-manuals-for-mode
           browse-help-current-mode)))
    (browse-help-message nil)))

 (let* ((repeat (equal topic browse-help-last-topic))
     ; ie. non-nil if browse-help-complete invoked with the same
     ; topic as when it was last invoked
     (matches (if repeat
      (eval 'browse-help-last-matches)
       (browse-help-all-completions topic)))
     (count (length matches)))
   (browse-help-debug "browse-help-complete - matches: %s" count)
   (cond ((> count 1)
    (if repeat
     ; scroll down through the completion list
     (progn
       (pop-to-buffer (get-buffer browse-help-buffer-name))
       (condition-case nil
        (scroll-up)
      (end-of-buffer (goto-line 1) (scroll-down 0)))
       (pop-to-buffer this-buffer))
      ; ... else display the list of completions
      (setq browse-help-completed-topic nil)
      (setq longest-match (try-completion topic matches))
      (if (not (equal longest-match t))
       (progn
      (browse-help-insert-match longest-match)
      (setq topic longest-match)))
      (setq browse-help-completed-topic (assoc topic matches))

      (setq this-buffer (current-buffer))
      (browse-help-mode-display-topics matches)
      (if browse-help-completed-topic
       (browse-help-tmp-message " [Complete, but not unique]"))
      (pop-to-buffer this-buffer)))
   ((= count 1)
    (setq browse-help-completed-topic (car matches))
    (browse-help-insert-match (car (car matches)))
    (browse-help-tmp-message " [Sole completion]"))
   ((= count 0)
    (browse-help-tmp-message " [No match]")))
   (setq browse-help-last-topic topic)
   (setq browse-help-last-matches matches))))

(defun browse-help-insert-match (topic)
  (delete-region (point-min) (point-max))
  (insert topic))

(defun browse-help-all-completions (partial)
  (save-match-data
    (let ((case-fold-search nil)
       ; needed because try-completion doesn't support case-insensitivity
    (topics))
      (mapc (function
      (lambda (entry)
        (let ((topic (nth 0 entry))
       (match (concat "^" (regexp-quote partial) ".*")))
   (if (string-match match topic)
       (setq topics (append topics (list entry)))))))
     browse-help-all-topics)
      (eval 'topics))))

(defun browse-help-try-completion (partial)
  (setq result (browse-help-all-completions partial))
  (if (> (length result) 1)
      (progn
 (eval 'partial))
    (if (= (length result) 1)
 (progn
   (eval 't))
      (eval nil))))

(defun browse-help-message (format &rest args)
  (apply 'browse-help-debug format args)
  (apply 'message format args))

(defun browse-help-debug (format &rest args)
  (if browse-help-debug-flag
      (print (apply 'format format args)
    (get-buffer-create "*Browse-Help-Debug*"))))

; Lifted from "filecache.el"
(defun browse-help-tmp-message (msg)
  "Print a temporary message to the current buffer."
  (let ((savemax (point-max)))
    (save-excursion
      (goto-char (point-max))
      (insert msg))
    (let ((inhibit-quit t))
      (sit-for 2)
      (delete-region savemax (point-max))
      (if (and quit-flag (not unread-command-events))
          (setq unread-command-events (list (character-to-event '(control G)))
                quit-flag nil)))))

;; --------------------------------------------------------------
;; Manual display functions
;; --------------------------------------------------------------

(defun browse-help-display-manual ()
  "Display manual."
  (interactive)
  (let ((manual (car (browse-help-get-manuals-for-mode mode-name)))
  (default-name)
  (manual-name)
  (msg))
    (if (not manual)
  (setq msg "Display manual: ")
   (setq default-name (browse-help-manual-name manual))
   (setq msg (format "Display manual (default %s): " default-name)))
 (if (null (featurep 'xemacs))
  (setq manual-name (completing-read msg (browse-help-get-manual-list)
             nil t nil nil default-name))
   (setq manual-name (completing-read msg (browse-help-get-manual-list)
           nil t nil nil))
   (if (equal "" manual-name)
    (setq manual-name default-name)))

    (browse-help-debug "manual name: %s" manual-name)
    (if (not (equal "" manual-name))
  (browse-help-mode-display-manual
   (browse-help-get-manual manual-name)))))

(defun browse-help-display-manuals-for-mode ()
  "Display all manuals associated with a mode."
  (interactive)
  (let ((manuals (browse-help-get-manuals-for-mode mode-name))
  (name)
  (msg)
  (modes))
 (if (not manuals)
  (setq msg "Display manuals for mode: ")
   (setq msg (format "Display manuals for mode (default %s): " mode-name)))

    (maphash (function
     (lambda (key manual)
    (loop for mode in (browse-help-manual-modes manual) do
      (if (and mode
         (not (assoc mode modes)))
       ; ie. if manual doesn't apply to all modes,
       ; and not already in list
       (setq modes (append modes (list (cons mode mode))))))))
    browse-help-manuals)
 (browse-help-debug "%s" modes)

 (setq name (completing-read msg modes))
 (if (equal name "")
  (setq name mode-name))
 (setq manuals (browse-help-get-manuals-for-mode name))
 (if manuals
  (browse-help-mode-display-manuals manuals) ; select default
   (browse-help-message "No manuals for mode %s" name))))

;; --------------------------------------------------------------
;; Manual search functions
;; --------------------------------------------------------------

(defun browse-help-get-url (manual-name topic)
  "Search manual named MANUAL-NAME for TOPIC.
Return a list of the form ((topic manual-name url)...), or nil,
if no match is found."
  (browse-help-debug "Looking up %s in %s" topic manual-name)
  (setq manual (browse-help-get-manual manual-name))
  (setq matches nil)
  (if manual
      (setq matches (browse-help-search-manual manual topic))
    (browse-help-message "Manual does not exist: %s" manual-name)))

(defun browse-help-search-manuals-for-mode (name topic)
  "Search all manuals associated with mode NAME for TOPIC.
Return a list of the form ((topic manual-name url)...), or nil,
if no match is found."
  (let ((manuals (browse-help-get-manuals-for-mode name)))
    (if manuals
  (setq matches (browse-help-search-manuals manuals topic))
      (browse-help-message "No manuals for %s mode" name)
      (setq matches nil))))

(defun browse-help-search-manuals (manuals topic)
  "Search list of manuals for TOPIC.
Return a list of the form ((topic manual-name url)...), or nil,
if no match is found."
  (let ((matches))
 (loop for manual in manuals do
   (browse-help-debug "searching %s for %s"
       (browse-help-manual-name manual) topic)
   (let ((topics (browse-help-search-manual manual topic)))
  (if topics
   (setq matches (nconc topics matches)))))
 (setq matches matches)))

(defun browse-help-search-manual (manual topic)
  "Search a manual for TOPIC.
Return a list of the form ((topic manual-name url)...), or nil,
if no match is found."
  (setq urls (gethash topic (browse-help-manual-hash manual)))
  (setq manual-name (browse-help-manual-name manual))
  (mapcar (function (lambda (url)
        (list topic manual-name url)))
   urls))

;; --------------------------------------------------------------
;; Manual load/save functions
;; --------------------------------------------------------------

(defun browse-help-init ()
  "Initialise Browse Help."
  (interactive)

  (setf browse-help-manuals (make-hash-table :test 'equal :size 255))

  (loop for help in browse-help-files do
 (let ((files (car help))
    (modes (cdr help)))
   (loop for elt in files do
  (let ((file (car elt))
     (prefix (cdr elt)))
    (let ((manual (browse-help-get-manual-for-file file)))
   (if manual
    ; already constructed a manual for this file - associate
    ; it with modes
    (browse-help-assoc-manual-with-modes manual modes)

    ; else encountered new manual...
     (let* ((base-name (file-name-nondirectory file))
      (name base-name)
      (count 2))
    ; generate a unique name for the manual
    (while (browse-help-get-manual name)
      (setq name (format "%s(%s)" base-name count))
      (incf count))
    ; add the manual, and associate it with modes
    (browse-help-add-manual name file modes prefix)))))))))

(defun browse-help-add-manual (name filename modes &optional prefix)
  "Add manual to the context-sensitive help.
NAME specifies a short name used to uniquely identify the manual.
FILENAME specifies the file to load the help from. This is parsed
by a parser selected from `browse-help-parsers'.
MODES is a list of mode names specifying the modes that the
manual applies to. If nil, the manual applies to all modes.
PREFIX is an optional argument specifying the prefix for
relative URLs. By default, this is derived from the full path
of filename."
  (save-excursion
    (browse-help-message "Adding manual %s from %s..." name filename)
    (let* ((lastmodified (nth 5 (file-attributes filename)))
    (manual (browse-help-create-manual name filename lastmodified))
    (ext (file-name-extension filename))
    (buffer (generate-new-buffer filename)))
      (if (not prefix)
    (setq prefix (concat "file:/" (file-name-directory
           (expand-file-name filename)))))
      ; load the manual
      (set-buffer buffer)
   (condition-case reason
    (progn
   (insert-file-contents-literally filename)
   (let ((regexp)
      (func)
      (parsers browse-help-parsers)
      (parser)
      (case-fold-search t))
     (while (and (car parsers) (null func))
    (setq parser (car parsers))
    (setq regexp (cdr parser))
    (if (string-match regexp filename)
     (setq func (car parser)))
    (setq parsers (cdr parsers)))
     (if (null func)
      (browse-help-message "No parser registered to load manual %s"
            filename)
    (funcall func manual buffer prefix)))
   (browse-help-assoc-manual-with-modes manual modes)
   (browse-help-message nil))
  (error (browse-help-message "Failed to add manual %s: %s" filename
         (get (car reason) 'error-message))))
      (kill-buffer buffer))))

(defun browse-help-save-manual (name filename)
  "Save manual named NAME in file FILENAME.
Entries are saved as tab-delimited topic/url pairs, suitable for
parsing by `browse-help-parse-in."
  (save-excursion
    (let ((buffer (generate-new-buffer filename)))
      (set-buffer buffer)
      (browse-help-output-manual-to-buffer name buffer)
      (write-region (point-min) (point-max) filename)
      (kill-buffer buffer))))

(defun browse-help-output-manual-to-buffer (name buffer)
  "Output manual named NAME to BUFFER.
Entries are output as tab delimited topic/url pairs."
  (save-excursion
    (let ((manual (browse-help-get-manual name))
   (topics))
      (if (not manual)
    (error (format "Manual %s does not exist" name)))
      (setq topics (browse-help-get-topics (list manual)))
      (set-buffer buffer)
      (setq standard-output buffer)
      (goto-char (point-min))
      (loop for entry in topics do
     (let ((topic (nth 0 entry))
     (url (nth 2 entry)))
       (princ (format "%s\t%s\n" topic url)))))))

(defconst browse-help-protocols "^\\(http\\|file\\|\\ftp\\):"
  "Specifies protocol prefixes for URLs.")

(defconst browse-help-expand-url nil "")

(defun browse-help-get-abs-url (url prefix filename)
  "Return an absolute URL given a relative URL.
If an absolute URL is supplied, it is returned unmodified.
PREFIX is an URL path.
FILENAME is the name of the HTML file."
  (if (string-match browse-help-protocols url)
   (setq url url)
 (if (not browse-help-expand-url)
  ; don't expand URLs (the fastest way...)
  (if (string-match "^#" url)
   (setq url (concat prefix filename url))
    (if (string-match "^./" url)
     (setq url (replace-match "" nil t url)))
    (setq url (concat prefix url)))
   ; else expand URLs - removes any redundant ../  from URLs
   ; - looks nicer, but is slower and may not work for all URLs....
   (let ((path prefix)
   (protocol))
  (if (string-match "^.*:" path)
   (progn
     (setq protocol (match-string 0 path))
     (setq path (replace-match "" nil t path))))
  (if (string-match "^./" url)
   (setq url (replace-match "" nil t url)))

  (if (string-match "^#" url)
   (setq url (concat (expand-file-name (concat path filename))
         url))
    (setq url (concat (expand-file-name (concat path url)))))
  (setq url (concat protocol url))))))

(defun browse-help-parse-index (manual buffer prefix)
  "Parse BUFFER and populate MANUAL with parsed entries.
BUFFER must be a buffer containing tab-delimited topic/url pairs.
PREFIX is a string used to fully qualify relative urls."
  (save-excursion
    (set-buffer buffer)
    (goto-char (point-min))
    (let ((filename (file-name-nondirectory
      (browse-help-manual-filename manual))))
      (while (not (eobp))
 (let ((point
        (re-search-forward "\\([^\t]*\\)\t\\([^\t]*\\)[\r]?\n" nil t))
       (url)
       (topic))
   (if (not point)
       (goto-char (point-max))
     (setq topic (buffer-substring (match-beginning 1) (match-end 1)))
     (setq url (buffer-substring (match-beginning 2) (match-end 2)))
     (setq url (browse-help-get-abs-url url prefix filename))
     (browse-help-add-topic manual topic url)))))))

(setq browse-help-re "<a href=\"\\([^\"]*\\)[^<]*>")

(defconst browse-help-subst-list
  '(("[\n\r]+" "")  ; removes carriage returns
    ("<[^>]*>" "")  ; removes bold/italic etc formatting
    ("^[ \t]+" "")  ; removes pre-whitespace
    ("[ \t]+$" "")  ; removes post-whitespace
    ("  +" " ")     ; replaces multiple spaces with one space
    ("&amp;" "&")
    ("&gt;" ">")
    ("&lt;" "<")
    ("&quot;" "\""))
  "List of (REGEXP STRING) entries, used to massage parsed HTML text.
Each REGEXP is applied in order, and any matches are replaced with
STRING.")

(defun browse-help-parse-html (manual buffer prefix)
  "Parse BUFFER and populate MANUAL with parsed entries.
BUFFER must be a buffer containing HTML text of the general form:

\t<a href=url>topic</a>

in order to be parsed sucessfully.
PREFIX is a string used to fully qualify relative urls."
  (save-excursion
    (set-buffer buffer)
    (goto-char (point-min))
    (let ((filename (file-name-nondirectory
      (browse-help-manual-filename manual)))
    (case-fold-search t)
    (point)
    (url)
    (topic))
      (while (not (eobp))
  (setq point (re-search-forward browse-help-re nil t))
  (if (not point)
   (goto-char (point-max))
    (setq url (buffer-substring (match-beginning 1) (match-end 1)))
    (setq url (browse-help-get-abs-url url prefix filename))

    (if (not (search-forward "</a>"))
     (goto-char (point-max))
   (setq topic (buffer-substring point (match-beginning 0)))

   (loop for regexp in browse-help-subst-list do
     (while (string-match (car regexp) topic)
    (setq topic (replace-match (cadr regexp) nil t topic))))
    ; perform any necessary replacements

   (if (and topic (not (equal topic "")))
    (browse-help-add-topic manual topic url))))))))

;; --------------------------------------------------------------
;; Browser support
;; --------------------------------------------------------------

(defun browse-help-launch-browser (url)
  "Launch browser with the supplied url by invoking
`browse-help-browser-function'."
  (browse-help-debug "Launching browser for %s" url)
  (funcall browse-help-browser-function url))

;; --------------------------------------------------------------
;; Browse help internals
;; --------------------------------------------------------------

(defstruct browse-help-manual name hash filename modes lastmodified)

(defvar browse-help-manuals nil "")

(defvar browse-help-debug-flag nil "")

(defun browse-help-debug (format &rest args)
  (if browse-help-debug-flag
   (if format
    (print (apply 'format format args)
     (get-buffer-create "*Browse-Help-Debug*")))))

(defun browse-help-get-manual-list ()
  "Return a list of all manuals."
  (let ((manuals))
    (maphash (function
     (lambda (key value)
    (setq manuals (cons (cons key value) manuals))))
    browse-help-manuals)
    (setq manuals manuals)))

(defun browse-help-get-manual-for-file (filename)
  "Return manual loaded from FILENAME."
  (let ((manual))
 (maphash (function
     (lambda (key value)
    (if (equal (browse-help-manual-filename value) filename)
     (setq manual value))))
    browse-help-manuals)
 (setq manual manual)))

(defun browse-help-get-manuals-for-mode (name)
  "Return a list of manuals for mode named NAME."
  (let ((manuals))
 (if browse-help-manuals
  (maphash (function
      (lambda (key manual)
     (let ((modes (browse-help-manual-modes manual)))
       (browse-help-debug "modes %s" modes)
       (if (or (member name modes)
         (member nil modes))
        (setq manuals (nconc manuals (list manual)))))))
     browse-help-manuals))
 (setq manuals manuals)))

(defun browse-help-assoc-manual-with-modes (manual modes)
  "Associate MANUAL with a list of mode names.
If MODES is nil, then the manual is associated with all modes."
  (browse-help-debug "assoc %s with %s" (browse-help-manual-name manual) modes)
  (let ((existing (browse-help-manual-modes manual)))
 (if modes
  (loop for mode in modes do
    (setq existing (browse-help-manual-modes manual))
    (if (not (member mode existing))
     (setf (browse-help-manual-modes manual)
     (append existing (list mode)))))
   (if (not (member nil existing))
    (setf (browse-help-manual-modes manual)
    (append existing '(nil))))))
  (browse-help-debug "assoc-end %s" (browse-help-manual-modes manual)))

(defun browse-help-get-manual (manual-name)
  "Return manual named MANUAL-NAME."
  (gethash manual-name browse-help-manuals))

(defun browse-help-create-manual (manual-name filename lastmodified)
  "Create manual named MANUAL-NAME."
  "Any existing manual with the same name will be deleted."
  (setf (gethash manual-name browse-help-manuals)
 (make-browse-help-manual
  :name manual-name
  :hash (make-hash-table :test 'equal :size 1023)
  :filename filename
  :lastmodified lastmodified))
  (gethash manual-name browse-help-manuals))

(defun browse-help-delete-manual (manual-name)
  "Delete manual named MANUAL-NAME."
  (remhash manual-name browse-help-manuals))

(defun browse-help-add-topic (manual topic url)
  "Add TOPIC with corresponding URL to MANUAL."
  (setq match (gethash topic (browse-help-manual-hash manual)))
  (if match
    (if (not (find url match :test 'equal))
  (setq match (nconc match (list url))))
    (setf (gethash topic (browse-help-manual-hash manual)) (list url))))

(defun browse-help-get-topics (manuals)
  "Return all topics in MANUALS as a sorted list.
The list is of the form ((topic manual-name url))(...)\),
sorted on topic."
  (let ((topics)
 (manual-name))
    (loop for manual in manuals do
   (setq manual-name (browse-help-manual-name manual))
   (maphash (function
    (lambda (topic urls)
      (loop for url in urls do
     (setq topics
        (cons (list topic manual-name url)
        topics)))))
      (browse-help-manual-hash manual)))
    (setq topics (sort topics (function
          (lambda (a b)
         (string< (car a) (car b))))))))

;; --------------------------------------------------------------
;; Browse help init
;; --------------------------------------------------------------

(if browse-help-init-after-load
 ; can now safely call browse-help-init...
 (browse-help-init))

;; --------------------------------------------------------------
;; Browse help mode
;; --------------------------------------------------------------

(defvar browse-help-mode-map nil "Keymap used in Browse Help buffer.")

(if browse-help-mode-map
    ()
  (let ((map (make-sparse-keymap)))
 (suppress-keymap map t)
 (define-key map "c" 'browse-help-mode-copy-url)
 (define-key map "q" 'quit-window)
 (define-key map " " 'browse-help-mode-next-line)
 (define-key map "n" 'browse-help-mode-next-line)
 (define-key map "p" 'browse-help-mode-previous-line)
 (define-key map [down] 'browse-help-mode-next-line)
 (define-key map [up] 'browse-help-mode-previous-line)
 (define-key map [return] 'browse-help-mode-select)
 (if (featurep 'xemacs)
  (define-key map [button2] 'browse-help-mode-mouse-select)
   (define-key map [mouse-2] 'browse-help-mode-mouse-select))
 (define-key map "?" 'describe-mode)
 (setq browse-help-mode-map map)))

(defun browse-help-mode ()
  "Major mode for buffers showing lists of possible help topics.
\\<browse-help-mode-map>
\\[browse-help-mode-mouse-select] -- browse selected help.
\\[browse-help-mode-select] -- browse selected help.
\\[browse-help-mode-next-line] -- select the next line.
\\[browse-help-mode-previous-line] -- select the previous line.
\\[browse-help-mode-copy-url] -- copy the url for the selected line.
\\[quit-window] -- quit the topic window."
  (kill-all-local-variables)
  (use-local-map browse-help-mode-map)
  (setq major-mode 'browse-help-mode)
  (put 'browse-help-mode 'mode-class 'special)
  (setq mode-name "Browse Help")
  (setq truncate-lines t)
  (setq buffer-read-only t)

  (browse-help-mode-setup-show-info)

  (goto-line 5)
  (run-hooks 'browse-help-mode-hook))

(defun browse-help-mode-setup-show-info ()
  (save-excursion
 (let ((buffer (get-buffer browse-help-buffer-name)))
   (if (not buffer)
    ()
  (set-buffer buffer)
  (setq browse-help-mode-display-info-flag
     (or browse-help-show-url-flag
      browse-help-show-manual-flag))
  (if browse-help-mode-display-info-flag
   (if (featurep 'xemacs)
    (setq mode-motion-hook 'browse-help-mode-track-mouse-xemacs)
     (define-key browse-help-mode-map [mouse-movement]
    'browse-help-mode-track-mouse)
     (make-local-variable 'track-mouse)
     (setq track-mouse t))
    (if (featurep 'xemacs)
     (setq mode-motion-hook nil)
   (define-key browse-help-mode-map [mouse-movement] nil)))))))

(defun browse-help-mode-display-manuals (manuals)
  (let ((topics (browse-help-get-topics manuals)))
    (browse-help-mode-display-topics topics)))

(defun browse-help-mode-display-manual (manual)
    (browse-help-mode-display-topics (browse-help-get-topics (list manual))))

(defun browse-help-mode-display-topics (topics)
  "Display help topics to a Browse Help buffer.
TOPICS must be a list of the form \(\(manual-name topic url\)...\)."
  (save-excursion
    (let ((buffer (get-buffer-create browse-help-buffer-name)))
      (set-buffer buffer)
      (setq buffer-read-only nil)
      (erase-buffer)
      (goto-char (point-min))
      (setq standard-output (current-buffer))
      (princ (format "Click %s on a topic to display its help\n"
       (key-description [mouse-2])))
      (princ "\n")
      (princ "Possible topics are: \n\n")

      (mapc (function
      (lambda (entry)
        (let ((topic (nth 0 entry))
       (manual-name (nth 1 entry))
       (url (nth 2 entry)))
   (browse-help-mode-display-topic manual-name topic url))))
     topics)
      (goto-char (point-min))
      (browse-help-mode)
      (pop-to-buffer buffer))))

(defun browse-help-mode-display-topic (manual-name topic url)
  "Display a help topic in the current buffer."
;  (browse-help-debug "browse-help-mode-display-topic")
  (let ((help-start (point))
  (help-end)
  (line-start))
    (if (or (null topic) (string= topic ""))
  (setq topic "<blank>"))
 (beginning-of-line)
 (setq line-start (point))
 (goto-char help-start)
    (princ topic)
    (setq help-end (point))

    (let ((start-col (- help-start line-start))
    (end-col (- help-end line-start))
    (strlen))
      (if (or (>= start-col 35) (>= (length topic) 35))
    (princ "\n")
  (setq strlen (- 35 end-col))
  (princ (make-string strlen 32))))

    (put-text-property help-start help-end 'mouse-face 'highlight)
    (put-text-property help-start help-end 'browse-help-url-prop
        (list topic manual-name url))))
    ; stick topic into the property for convenience

(defun browse-help-mode-selected-topic ()
  "Return the current selected topic.
This is a list of the form (topic manual-name url)"
  (if (not (equal (point) (point-max)))
      (get-text-property (point) 'browse-help-url-prop)))

(defun browse-help-browse-selected-url ()
  "Return the current selected URL."
  (let ((url (nth 2 (browse-help-mode-selected-topic))))
    (if url
  (progn (browse-help-message "Browsing %s" url)
      (shell-execute-url url))
      (browse-help-message "No URL selected"))))

(defun browse-help-mode-select ()
  "Browse the selected URL."
  (interactive)
  (browse-help-browse-selected-url))

(defun browse-help-mode-mouse-select (event)
  "Browse the selected URL."
  (interactive "e")
  (save-excursion
 (if (featurep 'xemacs)
  (progn
    (set-buffer (event-buffer event))
    (goto-char (event-point event)))
   (set-buffer (window-buffer (posn-window (event-end event))))
   (goto-char (posn-point (event-end event))))
    (browse-help-browse-selected-url)))

(defun browse-help-mode-next-line ()
  "Go to the next line."
  (interactive)
  (forward-line 1)
  (if browse-help-mode-display-info-flag
   (browse-help-mode-info)))

(defun browse-help-mode-previous-line ()
  "Go to the previous line."
  (interactive)
  (forward-line -1)
  (if browse-help-mode-display-info-flag
   (browse-help-mode-info)))

(defun browse-help-mode-copy-url ()
  "Copy the selected URL to the kill ring."
  (interactive)
  (let ((url (nth 2 (browse-help-mode-selected-topic))))
    (if url
  (kill-new url))))

(defun browse-help-mode-track-mouse-xemacs (event)
  "Display information about the topic selected by the mouse."
  (save-excursion
 (let ((pos (event-point event)))
      (if (null pos)
    (browse-help-message nil)
  (goto-char pos)
  (browse-help-mode-info)))))

(defun browse-help-mode-track-mouse (event)
  "Display information about the topic selected by the mouse."
  (interactive "e")
  (save-excursion
 (let ((pos (nth 1 (car (cdr event)))))
      (if (not (numberp pos))    ; check to see if mouse is on mode-line etc
    (browse-help-message nil)
  (goto-char pos)
  (browse-help-mode-info)))))

(defun browse-help-mode-info ()
  "Display info about the current selected topic."
  (let ((topic (browse-help-mode-selected-topic)))
    (let (message-log-max)   ; don't log urls
      (if topic
    (let ((manual (nth 1 topic))
    (url (nth 2 topic)))
   (if (and browse-help-show-url-flag
      browse-help-show-manual-flag)
    (browse-help-message "%s: %s" manual url)
     (if browse-help-show-url-flag
      (browse-help-message "%s" url)
    (browse-help-message "%s" manual))))
  (browse-help-message nil)))))

(provide 'browse-help)
