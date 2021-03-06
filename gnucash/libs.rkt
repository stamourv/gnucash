#lang racket/base

(require sxml
         (lib "time.ss" "srfi" "19")
         racket/match
         "typed-libs.rkt"
         memoize
         rackunit
         racket/contract)
  
;; an account is an sxml datum. It looks like this. Ooh, I'd forgotten
;; how much I hated XML...
#;'(http://www.gnucash.org/XML/gnc:account
  (@ (version "2.0.0"))
  (http://www.gnucash.org/XML/act:name "Root Account")
  (http://www.gnucash.org/XML/act:id
   (@ (type "guid"))
   "ab7ccf91bac526bb8effe6009b97fdfe")
  (http://www.gnucash.org/XML/act:type "ROOT"))
;; an account has a version attribute, and these elements:
;; - name (string)
;; - id (attribute type) (string)
;; - type
;; - optional parent
;; - optional currency
;; - optional commodity-scu
;; - optional slots

;; a transaction is an xml element



;; this provide is way too coarse, but I can't be bothered to fix it.
(provide (except-out (all-defined-out)
                     all-splits
                     group-by-account
                     account-group->dataset)
         (contract-out 
          [all-splits (-> transaction?
                          splitlist/c)]
          [group-by-account (-> splitlist/c
                                (listof
                                 (list/c id-string? 
                                         splitlist/c)))]
          [account-group->dataset
           (-> (list/c id-string? splitlist/c)
               (list/c account? (listof (list/c time? number?))))
]))

(define transaction? list?)
(define account? list?)
(define split? list?)
(define id-string? string?)
(define splitlist/c (listof (list/c time? split?)))

;; this explicit init is gross, but fixing it would require going to units.
(define book-ids #f)
(define count-data #f)
(define commodities #f)
(define accounts #f)
(define transactions #f)

(define (init-libs list-of-things)
  (set! book-ids (tag-filter book-id-tag list-of-things))
  (set! count-data (tag-filter count-data-tag list-of-things))
  (set! commodities (tag-filter commodity-tag list-of-things))
  (set! accounts (tag-filter account-tag list-of-things))
  (set! transactions (tag-filter transaction-tag list-of-things)))
  

;; find a given tag, signal an error if missing or more than one
(define (find-tag elt tag-list)
  (define proc (sxpath tag-list))
  (unless (procedure? proc)
    (raise-argument-error 'find-tag
                          "tag-list that works with sxpath"
                          1 elt tag-list))
  (oo/fail (proc elt)
           (lambda ()
             (raise-argument-error 'find-tag
                                   (format "element with tags ~v" tag-list)
                                   0 elt tag-list))))

;; find the single element in the given tag
(define (find-tag/1 elt tag-list)
  (oo/fail (sxml:content (find-tag elt tag-list))
           (lambda ()
             (raise-argument-error 'find-tag
                                   (format 
                                    "element with tags ~v containing exactly one element"
                                    tag-list)
                                   0 elt tag-list))))

; given a transaction, return its date.
(define (transaction-date transaction) 
  (string->date 
   (find-tag/1 transaction (list date-posted-tag date-tag))
   "~Y-~m-~d ~H:~M:~S ~z"))
  
;; given an account, return its name or false
(define (account-name account)
  (oof (sxml:content (find-tag account (list account-name-tag)))))
  
;; return the parent of an account, or #f if it has none
(define (account-parent account)
  (match (oof ((sxpath (list account-parent-tag)) account))
    [#f #f]
    [other (oo (sxml:content other))]))
  
;; return the id of an account
(define (account-id account)
  (find-tag/1 account (list account-id-tag)))
  
;; return the splits of a transaction
(define (transaction-splits t)
  (sxml:content (find-tag t (list splits-tag))))

;; return the currency of a transaction
(define (transaction-currency t)
  (find-tag t (list transaction-currency-tag)))

;; is this the account or the id of the account?
(define (split-account s)
  (find-tag/1 s (list split-account-tag)))
  
(define (split-value s)
  (string->number (find-tag/1 s (list split-value-tag))))
  
(define (id->account id)
  (oo (filter (lambda (account) (string=? id (account-id account))) accounts)))

;; an account-tree is
;; - (make-acct-tree name acct (listof account-tree)

;; find the account with a given path of names
;; memoization here is totally vital
(define/memo (account-name-path account)
  (reverse (let loop ([account account])
             (let ([maybe-parent (account-parent account)])
               (cons (account-name account)
                     (if maybe-parent
                         (loop (id->account maybe-parent))
                         null))))))
  

;; find an account with the given name path
(define (find-account name-path)
  (oo/fail (filter (lambda (acct) (equal? (account-name-path acct) name-path))
                   accounts)
           (lambda () (format "no account named ~v" name-path))))

;; find accounts whose name path starts with the given prefix
(define (find-account/prefix name-path)
  (filter (lambda (acct) (prefix? name-path (account-name-path acct)))
          accounts))
  
;; list list -> boolean
(define (prefix? a b)
  (match (list a b)
    [(list (list) any) #t]
    [(list (cons a arest) (cons b brest)) (and (equal? a b) (prefix? arest brest))]
    [else #f]))
  
(check-true (prefix? `() `()))
(check-true (prefix? `(a) `(a)))
(check-false (prefix? `(a b) `(a c)))
(check-true (prefix? `(a b c) `(a b c d)))

;; date date -> (transaction -> boolean)
(define (make-date-filter start end)
  (lambda (transaction)
    (let ([ttime (date->time-utc (transaction-date transaction))]
          [stime (date->time-utc start)]
          [etime (date->time-utc end)])
      (and (time<=? stime ttime)
           (time<? ttime etime)))))
  

(define (make-year-filter year)
  (make-date-filter (srfi:make-date 0 0 0 0 1 1 year 0)
                    (srfi:make-date 0 0 0 0 1 1 (+ year 1) 0)))
  
  (define (year->transactions year) (filter (make-year-filter year) transactions))
  
;; find all transactions where at least one split is in the list of 
;; account ids and one split is outside the list.
(define (crossers transactions account-ids)
  (filter (lambda (transaction)
            (let ([split-account-ids (map split-account (sxml:content (transaction-splits transaction)))])
              (and (ormap (lambda (id) (member id account-ids))
                          split-account-ids)
                   (ormap (lambda (id) (not (member id account-ids)))
                          split-account-ids))))
          transactions))
  
  ;; compute the net of the transaction w.r.t. the given accounts.
  (define (net transaction acct-ids currency)
    (unless (equal? (transaction-currency transaction) currency)
      (error 'net "transaction has wrong currency; expected ~v, got ~v" currency (transaction-currency transaction)))
    (let ([splits (sxml:content (transaction-splits transaction))])
      (foldl + 0 (map split-value (filter (lambda (s) (not (member (split-account s) acct-ids))) splits)))))
  
  ;; returns the splits of the transaction that do not involve the given accounts
  (define (external-splits transaction account-ids)
    (let* ([splits (sxml:content (transaction-splits transaction))]
           [date (transaction-date transaction)]
           [externals (filter (lambda (s) (not (member (split-account s) account-ids))) splits)])
      (map (lambda (split) (list (date->time-utc date) split)) externals)))

  ;; returns all the splits of the transaction
  (define (all-splits transaction)
    (let* ([splits (sxml:content (transaction-splits transaction))]
           [date (transaction-date transaction)])
      (map (lambda (split) (list (date->time-utc date) split)) splits)))
  
  (define (print-transaction t)
    (printf "~a\n" (date->string (transaction-date t)))
    (unless (equal? (transaction-currency t) dollars)
      (printf "NON-DOLLAR TRANSACTION\n"))
    (for-each print-split (transaction-splits t)))
  
  (define (print-split s)
    (printf "~v : ~v\n" (account-name-path (id->account (split-account s))) (split-value s)))
  
  

;; ********
  
(define (jan-one year) (srfi:make-date 0 0 0 0 1 1 year 0))
(define (feb-one year) (srfi:make-date 0 0 0 0 1 2 year 0))
(define (mar-one year) (srfi:make-date 0 0 0 0 1 3 year 0))
(define (apr-one year) (srfi:make-date 0 0 0 0 1 4 year 0))
(define (may-one year) (srfi:make-date 0 0 0 0 1 5 year 0))
(define (jun-one year) (srfi:make-date 0 0 0 0 1 6 year 0))
(define (jul-one year) (srfi:make-date 0 0 0 0 1 7 year 0))
(define (aug-one year) (srfi:make-date 0 0 0 0 1 8 year 0))
(define (sep-one year) (srfi:make-date 0 0 0 0 1 9 year 0))
(define (oct-one year) (srfi:make-date 0 0 0 0 1 10 year 0))
(define (nov-one year) (srfi:make-date 0 0 0 0 1 11 year 0))
(define (dec-one year) (srfi:make-date 0 0 0 0 1 12 year 0))


  
  
;; organize a list of date-and-splits by account
(define (group-by-account date-and-splits)
  (hash-map
   (for/fold ([ht (hash)])
             ([date-and-split (in-list date-and-splits)])
     (let ([id (split-account (cadr date-and-split))])
       (hash-set ht id (cons date-and-split (hash-ref ht id `())))))
   list))

(define (generate-budget-report grouped)
  (map (match-lambda [(list id splits) 
                      (list (account-name-path (id->account id))
                            (apply + (map split-value (map cadr splits))))])
       grouped))

  (define (budget-report s e accounts)
    (generate-budget-report (splits-by-account s e (map account-id accounts))))
  
  (define (splits-by-account s e acct-ids)
    (let* ([crossers (crossers (transactions-in-range s e) acct-ids)]
           [external-motion (apply append (map (lambda (transaction)
                                                 (external-splits transaction acct-ids))
                                               crossers))])
      (group-by-account external-motion)))
  
  (define (transactions-in-range s e)
    (filter (make-date-filter s e) transactions))
  
  (define (pair-up a b)
    (let ([ht (make-hash)])
      (for-each (match-lambda 
                  [(list k v) (hash-set! ht k (list v))])
                a)
      (for-each (match-lambda 
                  [(list k v) (hash-set! ht k (cons v (hash-ref ht k (list 0))))])
                b)
      (hash-map ht (lambda (k v) (match v 
                                   [(list a b) (list k b a)]
                                   [(list a) (list k a 0)])))))
  
  (define (expenses-only br)
    (filter (match-lambda [(list name a b)
                           (cond [(and (>= a 0) (>= b 0))
                                  #t]
                                 [(or (> a 0) (> b 0))
                                  (error 'expenses-only "account ~v has mixed-sign numbers: ~v and ~v" name a b)]
                                 [else #f])])
            br))
  
  (define (print-it a)
    (for-each (match-lambda [(list name a b) (printf "~a\t~v\t~v\n" (colonsep name) (digfmt a) (digfmt b))]) a))
  
  (define (colonsep strlist)
    (apply string-append (cons (car strlist) (map (lambda (x) (string-append ":" x)) (cdr strlist)))))
  
  (define (digfmt n)
    (/ (* n 100) 100.0))
  

;; given an account group, produce a dataset...
;; perhaps this should check to make sure it's a dollars transaction?
(define (account-group->dataset account-group)
  (list (id->account (car account-group))
        (for/list ([date-and-split (cadr account-group)])
          (list (car date-and-split) (split-value (cadr date-and-split))))))