;;; vinboard-archive.el --- Capture pages for vinboard in a browser-gt browser  -*- lexical-binding: t; -*-

;;; Commentary:

;; Renders a url in a browser connected through browser-gt - with the
;; user's own logins and cookies - and saves the page as MHTML.  The work
;; is asynchronous, so Emacs stays usable while a page loads:
;;
;;   (vinboard-archive-start URL FILE)
;;
;; returns at once; FILE appears when the capture is done, or FILE.err
;; with the reason when it failed.  FILE.url, written just before FILE,
;; holds the url the tab ended on, after any redirects.

;;; Code:

(require 'browser-gt)
(require 'cl-lib)
(require 'seq)

(defvar vinboard-archive-load-timeout 45
  "Seconds to wait for a page to finish loading.")

(defvar vinboard-archive-settle 2
  "Seconds to let a loaded page run its scripts before it is captured.")

(defvar vinboard-archive-challenge-re
  (rx (or "Just a moment" "Performing security verification" "Attention Required"
          "Checking your browser" "DDoS-Guard"))
  "Tab titles of bot checks.  Some clear themselves after a while; a page
still showing one at the load timeout is not captured.")

(defvar vinboard-archive-client nil
  "browser-gt client to archive in, or nil for the only connected one.")

(defconst vinboard-archive--scroll-js
  "(async () => {
     const step = Math.max(400, window.innerHeight);
     const end = Math.min(document.documentElement.scrollHeight, 40000);
     for (let y = 0; y < end; y += step) {
       window.scrollTo(0, y);
       await new Promise(r => setTimeout(r, 150));
     }
     window.scrollTo(0, 0);
     return true;
   })()"
  "Scroll through the page so lazily loaded content arrives.")

(defun vinboard-archive--request (name payload callback)
  "Send request NAME with PAYLOAD; call CALLBACK with the response."
  (browser-gt-request-async name payload callback vinboard-archive-client))

(defun vinboard-archive-start (url file)
  "Start capturing URL into FILE as MHTML; return immediately.
FILE.err receives the reason when the capture fails."
  (let ((err (concat file ".err")))
    (ignore-errors (delete-file file))
    (ignore-errors (delete-file err))
    (cl-labels
        ((fail (msg &optional tab)
           (when tab (vinboard-archive--close tab))
           (with-temp-file err (insert (format "%s" msg))))
         (ok-p (r) (equal (plist-get r :status) "ok"))
         (opened (tab)
           (let ((id (plist-get tab :id)))
             (if (not (numberp id))
                 (fail (format "could not open a tab: %S" tab))
               (wait id (+ (float-time) vinboard-archive-load-timeout)))))
         (wait (id deadline)
           (vinboard-archive--request
            "GET_ALL_TABS" nil
            (lambda (tabs)
              (let ((tab (seq-find (lambda (tb) (equal (plist-get tb :id) id))
                                   (if (listp tabs) tabs nil))))
                (cond ((null tab) (fail "the tab went away while loading"))
                      ((and (> (float-time) deadline)
                            (string-match-p vinboard-archive-challenge-re
                                            (or (plist-get tab :title) "")))
                       (fail "a bot check did not clear; pass it in the browser and retry" id))
                      ((> (float-time) deadline) (scroll id (plist-get tab :url)))
                      ((and (equal (plist-get tab :status) "complete")
                            (not (string-match-p vinboard-archive-challenge-re
                                                 (or (plist-get tab :title) ""))))
                       (scroll id (plist-get tab :url)))
                      (t (run-at-time 0.5 nil #'wait id deadline)))))))
         (scroll (id final)
           (vinboard-archive--request
            "EVAL_IN_ACTIVE_TAB" (list :tabId id :code vinboard-archive--scroll-js)
            (lambda (_)
              (run-at-time vinboard-archive-settle nil #'capture id 3 final))))
         (capture (id tries final)
           (vinboard-archive--request
            "CAPTURE_MHTML" (list :tabId id)
            (lambda (r)
              (cond
               ((and (not (ok-p r)) (> tries 1))
                ;; Capturing fails now and then on a page that just loaded.
                (run-at-time 1 nil #'capture id (1- tries) final))
               ((not (ok-p r))
                (fail (or (plist-get r :message) (format "%S" r)) id))
               (t
                (let ((coding-system-for-write 'utf-8-unix))
                  (when (stringp final)
                    (with-temp-file (concat file ".url") (insert final)))
                  (with-temp-file file (insert (plist-get r :mhtml))))
                (vinboard-archive--close id)))))))
      (vinboard-archive--request
       "OPEN_BACKGROUND_TAB" (list :url url :active :json-false)
       (lambda (tab)
         (condition-case e (opened tab)
           (error (fail (error-message-string e)))))))
    file))

(defun vinboard-archive--close (id)
  "Close tab ID, ignoring the answer."
  (vinboard-archive--request "CLOSE_TAB" (list :id id) #'ignore))

(provide 'vinboard-archive)
;;; vinboard-archive.el ends here
