;;; vinboard.el --- Emacs client for vinboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Pavel Popov
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: bookmarks, rest
;; URL: https://github.com/velppa/vinboard

;;; Commentary:

;; Emacs client for the vinboard self-hosted bookmark REST API.
;;
;; Usage:
;;   M-x vinboard-add    — add a bookmark (prompts for URL, title, tags)
;;   M-x vinboard-search — search bookmarks (prompts for query term)
;;
;; Configure the server URL and token via `vinboard-base-url' and
;; `vinboard-token' (or via M-x customize-group RET vinboard RET).

;;; Code:

(require 'json)
(require 'url)

;;;; Customization

(defgroup vinboard nil
  "Emacs client for the vinboard bookmark server."
  :group 'tools
  :prefix "vinboard-")

(defcustom vinboard-base-url "https://hotter.myaddr.dev/vinboard"
  "Base URL of the vinboard server (no trailing slash).
The Caddy reverse-proxy prefix is included here; the app itself
sees plain /api/… paths after Caddy strips the prefix."
  :type 'string
  :group 'vinboard)

(defcustom vinboard-token "uery3721lkjKd"
  "Query-parameter token used to authenticate every vinboard request."
  :type 'string
  :group 'vinboard)

;;;; Internal helpers

(defun vinboard--url (path &optional query)
  "Build a full vinboard URL for PATH with the auth token and optional QUERY.
QUERY is an alist of (KEY . VALUE) pairs appended as &KEY=VALUE."
  (concat vinboard-base-url
          path
          "?token=" (url-hexify-string vinboard-token)
          (mapconcat (lambda (kv)
                       (format "&%s=%s"
                               (car kv)
                               (url-hexify-string (format "%s" (cdr kv)))))
                     query
                     "")))

(defun vinboard--request (method path &optional body query)
  "Send an HTTP METHOD request to PATH with optional BODY and QUERY params.
BODY, when non-nil, is JSON-encoded and sent as the request body.
QUERY is an alist appended to the URL query string.
Returns the parsed JSON response (alist / list), or nil on empty body."
  (let* ((url-request-method method)
         (url-request-extra-headers '(("Content-Type" . "application/json")))
         (url-request-data (when body
                             (encode-coding-string (json-encode body) 'utf-8))))
    (with-current-buffer
        (url-retrieve-synchronously (vinboard--url path query) t)
      (goto-char (point-min))
      (when (re-search-forward "\n\n" nil t)
        (let ((json-object-type 'alist)
              (json-array-type  'list))
          (ignore-errors (json-read)))))))

;;;; Public commands

;;;###autoload
(defun vinboard-add (url &optional title tags)
  "Add a bookmark with URL, optional TITLE and space-separated TAGS string.
When called interactively, prompts for all three values."
  (interactive
   (list (read-string "URL: ")
         (read-string "Title (optional): ")
         (read-string "Tags (space-separated, optional): ")))
  (let* ((tag-list (if (and tags (not (string-empty-p (string-trim tags))))
                       (vconcat (split-string (string-trim tags)))
                     []))
         (body `((url   . ,url)
                 (title . ,(or title ""))
                 (tags  . ,tag-list)))
         (result (vinboard--request "POST" "/api/bookmarks" body)))
    (if result
        (message "vinboard: bookmark added with id %s"
                 (or (alist-get 'id result) "?"))
      (message "vinboard: bookmark POST returned no response"))))

;;;###autoload
(defun vinboard-search (query)
  "Search vinboard bookmarks for QUERY and display results in *vinboard*."
  (interactive "sSearch vinboard: ")
  (let ((results (vinboard--request "GET" "/api/search"
                                    nil `(("q" . ,query)))))
    (with-current-buffer (get-buffer-create "*vinboard*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "vinboard search: %s\n\n" query))
        (if (null results)
            (insert "No results.\n")
          (dolist (item results)
            (let ((title (or (alist-get 'title item) "(no title)"))
                  (burl  (or (alist-get 'url   item) "")))
              (insert (format "%s\n  %s\n\n" title burl))))))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

(provide 'vinboard)
;;; vinboard.el ends here
