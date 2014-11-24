;;; orgit.el --- support for Org links to Magit buffers

;; Copyright (C) 2014  The Magit Project Developers

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Maintainer: Jonas Bernoulli <jonas@bernoul.li>
;; Version: 0.1.0
;; Package-Requires: ((magit "2.1.0") (org "8"))

;; This library was inspired by `org-magit.el' which was written by
;; Yann Hodique <yann.hodique@gmail.com> and is distributed under the
;; GNU General Public License version 2 or later.

;; This library is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this library.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; This package defines several Org link types which can be used to
;; link to certain Magit buffers.
;;
;;    orgit:/path/to/repo/           links to a `magit-status' buffer
;;    orgit-log:/path/to/repo/::REV  links to a `magit-log' buffer
;;    orgit-rev:/path/to/repo/::REV  links to a `magit-commit' buffer

;; Such links can be stored from corresponding Magit buffers using
;; the command `org-store-link'.

;; When an Org file containing such links is exported, then the url of
;; the remote configured with `orgit-remote' is used to generate a web
;; url according to `orgit-export-alist'.  That webpage should present
;; approximately the same information as the Magit buffer would.

;; Both the remote to be considered the public remote, as well as the
;; actual web urls can be defined in individual repositories using Git
;; variables.

;; To use a remote different from `orgit-remote' but still use
;; `orgit-export-alist' to generate the web urls, use:
;;
;;    git config orgit.remote REMOTE-NAME

;; To explicitly define the web urls, use something like:
;;
;;    git config orgit.status http://example.com/repo/overview
;;    git config orgit.log http://example.com/repo/history/%r
;;    git config orgit.rev http://example.com/repo/revision/%r

;;; Code:

(require 'cl-lib)
(require 'dash)
(require 'format-spec)
(require 'magit)
(require 'org)

;;; Options

(defgroup orgit nil
  "Org links to Magit buffers."
  :group 'magit-extensions
  :group 'org-link)

(defcustom orgit-export-alist
  `(("github.com[:/]\\(.+?\\)\\(?:\\.git\\)?$"
     "https://github.com/%n"
     "https://github.com/%n/commits/%r"
     "https://github.com/%n/commit/%r")
    ("gitorious.org[:/]\\(.+?\\)\\(?:\\.git\\)?$"
     "https://gitorious.org/%n"
     "https://gitorious.org/%n/commits/%r"
     "https://gitorious.org/%n/commit/%r")
    ("bitbucket.org[:/]\\(.+?\\)\\(?:\\.git\\)?$"
     "https://bitbucket.org/%n"
     "https://bitbucket.org/%n/commits/branch/%r"
     "https://bitbucket.org/%n/commits/%r")
    ("orgmode.org[:/]\\(.+\\)$"
     "http://orgmode.org/cgit.cgi/%n"
     "http://orgmode.org/cgit.cgi/%n/log/?h=%r"
     "http://orgmode.org/cgit.cgi/%n/commit/?id=%r")
    ("git.kernel.org/pub/scm[:/]\\(.+\\)$"
     "http://git.kernel.org/cgit/%n"
     "http://git.kernel.org/cgit/%n/log/?h=%r"
     "http://git.kernel.org/cgit/%n/commit/?id=%r"))
  "Alist used to translate Git urls to web urls when exporting links.

Each entry has the form (REMOTE-REGEXP STATUS LOG COMMIT).
If a REMOTE-REGEXP matches the url of the choosen remote then one
of the corresponding format strings STATUS, LOG or COMMIT is used
according to the major mode of the buffer being linked to.

The first submatch of REMOTE-REGEXP has to match the repository
identifier (which usually consists of the username and repository
name).  The %n in the format string is replaced with that match.
LOG and COMMIT additionally have to contain %r which is replaced
with the appropriate revision.

This can be overwritten in individual repositories using the Git
variables `orgit.status', `orgit.log' and `orgit.commit'. The
values of these variables must not contain %n, but in case of the
latter two variables they must contain %r.  When these variables
are defined then `orgit-remote' and `orgit.remote' have no effect."
  :group 'orgit
  :type '(repeat (list :tag "Remote template"
                       (regexp :tag "Remote regexp")
                       (string :tag "Status format")
                       (string :tag "Log format" :format "%{%t%}:    %v")
                       (string :tag "Commit format"))))

(defcustom orgit-remote "origin"
  "Default remote used when exporting links.

If there exists but one remote, then that is used unconditionaly.
Otherwise if the Git variable `orgit.remote' is defined and that
remote exists, then that is used.  Finally the value of this
variable is used, provided it does exist in the given repository.
If all of the above fails then `orgit-export' raises an error."
  :group 'orgit
  :type 'string)

;;; Status

;;;###autoload
(eval-after-load "org"
  '(progn (org-add-link-type "orgit" 'orgit-status-open 'orgit-status-export)
          (add-hook 'org-store-link-functions 'orgit-status-store)))

(defun orgit-status-store ()
  (when (eq major-mode 'magit-status-mode)
    (let ((repo (abbreviate-file-name default-directory)))
      (org-store-link-props
       :type        "orgit"
       :link        (format "orgit:%s" repo)
       :description (format "%s (magit-status)" repo)))))

(defun orgit-status-open (path)
  (magit-status-internal (file-name-as-directory path) 'pop-to-buffer))

(defun orgit-status-export (path desc format)
  (orgit-export path desc format "status" 1))

;;; Log

;;;###autoload
(eval-after-load "org"
  '(progn (org-add-link-type "orgit-log" 'orgit-log-open 'orgit-log-export)
          (add-hook 'org-store-link-functions 'orgit-log-store)))

(defun orgit-log-store ()
  (when (eq major-mode 'magit-log-mode)
    (let ((repo (abbreviate-file-name default-directory))
          (rev  (cadr magit-refresh-args)))
      ;; FIXME Once version 2.1.0 of Magit is released,
      ;; support multi-rev logs.
      (when (listp rev)
        (setq rev (car rev)))
      (org-store-link-props
       :type        "orgit-log"
       :link        (format "orgit-log:%s::%s" repo rev)
       :description (format "%s (magit-log %s)" repo rev)))))

(defun orgit-log-open (path)
  (cl-destructuring-bind (default-directory rev)
      (split-string path "::")
    (magit-log (list rev))))

(defun orgit-log-export (path desc format)
  (orgit-export path desc format "rev" 2))

;;; Commit

;;;###autoload
(eval-after-load "org"
  '(progn (org-add-link-type "orgit-rev" 'orgit-rev-open 'orgit-rev-export)
          (add-hook 'org-store-link-functions 'orgit-rev-store)))

(defun orgit-rev-store ()
  (when (memq major-mode '(magit-commit-mode magit-revision-mode))
    (let ((repo (abbreviate-file-name default-directory))
          (rev  (car magit-refresh-args)))
      (org-store-link-props
       :type        "orgit-rev"
       :link        (format "orgit-rev:%s::%s" repo rev)
       :description (format "%s (magit-commit %s)" repo rev)))))

(defun orgit-rev-open (path)
  (cl-destructuring-bind (default-directory rev)
      (split-string path "::")
    (magit-show-commit rev)))

(defun orgit-rev-export (path desc format)
  (orgit-export path desc format "rev" 3))

;;; Export

(defun orgit-export (path desc format gitvar idx)
  (let* ((parts   (split-string path "::"))
         (rev     (cadr parts))
         (default-directory (car parts))
         (remotes (magit-git-lines "remote"))
         (remote  (magit-get "orgit.remote"))
         (remote  (cond ((= (length remotes) 1) (car remotes))
                        ((member remote remotes) remote)
                        ((member orgit-remote remotes) orgit-remote))))
    (if remote
        (-if-let
            (link (or (-when-let (url (magit-get "orgit" gitvar))
                        (format-spec url `((?r . ,rev))))
                      (-when-let (url (magit-get "remote" remote "url"))
                        (--when-let (--first (string-match (car it) url)
                                             orgit-export-alist)
                          (format-spec (nth idx it)
                                       `((?n . ,(match-string 1 url))
                                         (?r . ,rev)))))))
            (pcase format
              (`html  (format "<a href=\"%s\">%s</a>" link desc))
              (`latex (format "\\href{%s}{%s}" link desc))
              (`ascii link)
              (_      link))
          (error "Cannot determine public url for %s" path))
      (error "Cannot determine public remote for %s" default-directory))))

;;; orgit.el ends soon
(provide 'orgit)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; orgit.el ends here
