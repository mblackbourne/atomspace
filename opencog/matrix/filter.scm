;
; filter.scm
;
; Define API's for filtering the matrixes, e.g. by removing entries
; with low counts.
;
; Copyright (c) 2017 Linas Vepstas
;
; ---------------------------------------------------------------------
; OVERVIEW
; --------
; Large datasets are inherently likely to contain "noise" and spurious
; data that might be unwanted during data analysis. For example, the
; dataset might contian a large number of atoms that were observed only
; once or twice; these are likely to be junk and should be removed
; before data analysis begins.
;
; The code here provides this filtering ability. Several types of
; filters are provided:
; -- a knockout filter, that knocks out designated rows and columns.
; -- a min-count filter, that knocks out rows and columns whose
;    marginal counts are below a minimum, as well as individual matrix
;    entries that are below a per-entry minimum.
; -- a generic callback-defined filter, that knocks out rows, columns
;    and individual entries based on callback predicates.
;
; Note that these filters are all "on demand": they do NOT copy the
; dataset and then compute a smaller version of it.  Instead, they
; overload the "star" API, altering the methods used to fetch rows,
; columns and individual entries.  Since all the other matrix access
; routines use the "star" API to gain access to the matrix and it's
; marginals, this works!
;
; ---------------------------------------------------------------------

(use-modules (srfi srfi-1))

; ---------------------------------------------------------------------

(define-public (add-generic-filter LLOBJ
	LEFT-BASIS-PRED RIGHT-BASIS-PRED
	LEFT-STAR-PRED RIGHT-STAR-PRED
	PAIR-PRED ID-STR)
"
  add-generic-filter LLOBJ - Modify LLOBJ so that only the columns and
  rows that satisfy the predicates are retained.

  The LEFT-BASIS-PRED and RIGHT-BASIS-PRED should be functions that
  accept atoms in the left and right basis, and return #t if they
  should be kept.

  The LEFT-STAR-PRED and RIGHT-STAR-PRED should be functions that
  accept left and right wild-card pairs, and return #t if they should
  be kept.

  The PAIR-PRED should be a function to that accepts individual matrix
  entries. It is applied whenever the 'item-pair or 'pair-count methods
  are invoked.  Like the others, it should return #t to keep the pair.

  The ID-STR should be a string; it is appended to the dataset name and
  id, so that unique identifier names can be constructed for each
  filtered dataset.
"
	(let ((stars-obj (add-pair-stars LLOBJ))
			(l-basis '())
			(r-basis '())
			(l-size 0)
			(r-size 0)
		)

		; ---------------
		; Filter out rows and columns that pass the left and right
		; predicates.
		(define (do-left-basis)
			(filter LEFT-BASIS-PRED (stars-obj 'left-basis)))

		(define (do-right-basis)
			(filter RIGHT-BASIS-PRED (stars-obj 'right-basis)))

		; ---------------
		; Use the cached value, if its there.
		(define (get-left-basis)
			(if (null? l-basis) (set! l-basis (do-left-basis)))
			l-basis)

		(define (get-right-basis)
			(if (null? r-basis) (set! r-basis (do-right-basis)))
			r-basis)

		(define (get-left-size)
			(if (eq? 0 l-size) (set! l-size (length (get-left-basis))))
			l-size)

		(define (get-right-size)
			(if (eq? 0 r-size) (set! r-size (length (get-right-basis))))
			r-size)

		; ---------------
		; Return only those stars that pass the cutoff.
		;
		(define (do-left-stars ITEM)
			(filter
				(lambda (PAIR)
					(and (LEFT-STAR-PRED PAIR) (PAIR-PRED PAIR)))
				(stars-obj 'left-stars ITEM)))

		(define (do-right-stars ITEM)
			(filter
				(lambda (PAIR)
					(and (RIGHT-STAR-PRED PAIR) (PAIR-PRED PAIR)))
				(stars-obj 'right-stars ITEM)))

		; Cache the results above, so that we don't recompute over and over.
		(define cache-left-stars (make-afunc-cache do-left-stars))
		(define cache-right-stars (make-afunc-cache do-right-stars))

		; ---------------
		; Apply the pair-cut to each pair.
		(define (get-item-pair PAIR)
			(if (PAIR-PRED PAIR) (LLOBJ 'item-pair PAIR) '()))

		(define (get-pair-count PAIR)
			(if (PAIR-PRED PAIR) (LLOBJ 'pair-count PAIR) 0))

		; ---------------
		(define (get-name)
			(string-append (LLOBJ 'name) " " ID-STR))
		(define (get-id)
			(string-append (LLOBJ 'id) " " ID-STR))

		; ---------------
		; Return a pointer to each method that this class overloads.
		(define (provides meth)
			(case meth
				((left-stars)       cache-left-stars)
				((right-stars)      cache-right-stars)
				((left-basis)       get-left-basis)
				((right-basis)      get-right-basis)
				((left-basis-size)  get-left-size)
				((right-basis-size) get-right-size)
				(else               (LLOBJ 'provides meth))))

		; -------------
		; Methods on this class.
		(lambda (message . args)
			(case message
				((name)             (get-name))
				((id)               (get-id))
				((left-stars)       (apply cache-left-stars args))
				((right-stars)      (apply cache-right-stars args))
				((left-basis)       (get-left-basis))
				((right-basis)      (get-right-basis))
				((left-basis-size)  (get-left-size))
				((right-basis-size) (get-right-size))
				((item-pair)        (apply get-item-pair args))
				((pair-count)       (apply get-pair-count args))
				((provides)         (apply provides args))
				((filters?)         (lambda () #t))
				; Pass through some selected methods
				((left-type)        (apply LLOBJ (cons message args)))
				((right-type)       (apply LLOBJ (cons message args)))
				((pair-type)        (apply LLOBJ (cons message args)))
				; Block anything that might have to be filtered.
				; For example: 'pair-freq which we don't, can't filter.
				; Or any of the variious subtotals and marginals.
				(else               (throw 'bad-use 'add-generic-filter
					(format #f "Sorry, method ~A not available on filter!" message))))
		)))

; ---------------------------------------------------------------------

(define-public (add-subtotal-filter LLOBJ LEFT-CUT RIGHT-CUT PAIR-CUT)
"
  add-subtotal-filter LLOBJ - Modify LLOBJ so that any columns and
  rows with counts less than LEFT-CUT and RIGHT-CUT are removed, and that
  individual entries with counts less than PAIR-CUT are removed. This
  provides an API compatible with the star-object API; i.e. it provides
  the same row and column addressability that star-object does, but
  just returns fewer rows, columns and individual entries.

  The filtering is done 'on demand', on a row-by-row, column-by-column
  basis.  Computations of the left and right stars are cached, sot that
  they are not recomputed for each request.

  Note that by removing rows and columns, the frequencies will no longer
  sum to 1.0. Likewise, row and column subtotals, entropies and mutual
  information will no long sum or behave as in the whole dataset.  If
  accurate values for these are needed, then they would need to be
  recomputed for the reduced matrix.

  Some terminology: Let N(x,y) be the observed count for the pair (x,y).
  Let N(*,y) be the column subtotals, AKA the left-subtotals.
  Let N(x,*) be the row subtotals, AKA the right subtotals.

  This object removes all columns where  N(*,y) <= RIGHT-CUT and where
  N(x,*) <= LEFT-CUT.  Pairs are not reported in the 'left-stars and
  'right-stars methods when N(x,y) <= PAIR-CUT.

  The net effect of the cuts is that when LEFT-CUT is increased, the
  left-dimension of the dataset drops; likewise on the right.
"
	(let* ((stars-obj (add-pair-stars LLOBJ))
			(cnt-obj (add-pair-count-api stars-obj))
		)

		; ---------------
		; Filter out rows and columns that are below-count.
		;
		; Yes, we want LEFT-CUT < right-wild-count this looks weird,
		; but is correct: as LEFT-CUT gets larger, the size of the
		; left-basis shrinks.
		(define (left-basis-pred ITEM)
			(< LEFT-CUT (cnt-obj 'right-wild-count ITEM)))

		(define (right-basis-pred ITEM)
			(< RIGHT-CUT (cnt-obj 'left-wild-count ITEM)))

		; ---------------
		; Return only those stars that pass the cutoff.
		;
		; See comments above: LEFT-CUT < right-wild-count is correct.
		(define (left-stars-pred PAIR)
			(< LEFT-CUT (cnt-obj 'right-wild-count (gar PAIR))))

		(define (right-stars-pred PAIR)
			(< RIGHT-CUT (cnt-obj 'left-wild-count (gdr PAIR))))

		(define (pair-pred PAIR)
			(< PAIR-CUT (LLOBJ 'pair-count PAIR)))

		(define id-str
			(format #f "cut-~D-~D-~D"
				LEFT-CUT RIGHT-CUT PAIR-CUT))

		; ---------------
		(add-generic-filter LLOBJ
			left-basis-pred right-basis-pred
			left-stars-pred right-stars-pred
			pair-pred id-str)
	)
)

; ---------------------------------------------------------------------

(define-public (add-knockout-filter LLOBJ LEFT-KNOCKOUT RIGHT-KNOCKOUT)
"
  add-knockout-filter LLOBJ - Modify LLOBJ so that the explicitly
  indicated rows and columns are removed. The LEFT-KNOCKOUT and
  RIGHT-KNOCKOUT should be lists of left and right basis elements.
"
	; ---------------
	; Filter out rows and columns in the knockout lists.
	;
	(define (left-basis-pred ITEM)
		(not (any
			(lambda (knockout) (equal? knockout ITEM))
			LEFT-KNOCKOUT)))

	(define (right-basis-pred ITEM)
		(not (any
			(lambda (knockout) (equal? knockout ITEM))
			RIGHT-KNOCKOUT)))

	; ---------------
	; Return only those stars that pass the cutoff.
	(define (left-stars-pred PAIR)
		(left-basis-pred (gar PAIR)))

	(define (right-stars-pred PAIR)
		(right-basis-pred (gdr PAIR)))

	(define (pair-pred PAIR)
		(and (left-stars-pred PAIR) (right-stars-pred PAIR)))

	(define id-str
		(format #f "knockout-~D-~D"
			(length LEFT-KNOCKOUT) (length RIGHT-KNOCKOUT)))

	; ---------------
	(add-generic-filter LLOBJ
		left-basis-pred right-basis-pred
		left-stars-pred right-stars-pred
		pair-pred id-str)
)

; ---------------------------------------------------------------------