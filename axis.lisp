(in-package :cl-2d)

(declaim (optimize (debug 3) (speed 0)))

;;;;  Axis
;;;;
;;;;  An axis is simply a collection of positions (for ticks), some of
;;;;  which may have labels.  Most of the time, axes are autogenerated
;;;;  (see autoaxis-pick-best below), but they can be specified
;;;;  manually.

(defclass axis () 
  (;;(interval :initarg :interval :documentation "interval")
   (positions :initarg :positions :type list :reader axis-positions
	      :documentation "positions of tickmarks, in drawing-area ~
	      coordinates")
   (marks :initarg :marks :type list :reader axis-marks 
	  :documentation "labels at tickmarks"))
  (:documentation "If a mark is nil, no label is drawn there and it is
  omitted when checking for overlapping text.  Use the string \"\" to
  check for the latter."))

(defmethod print-object ((obj axis) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "positions=~a~%marks=~a" (axis-positions obj)
	    (axis-marks obj))))

;;;;  Axis autogeneration
;;;;
;;;;  Axis autogeneration is by trial and error: we try different
;;;;  arrangement of marks and see which one works best.  Marks should
;;;;  not overlap and there should be some space between them is
;;;;  possible, but given that, we should try to fit as many as we
;;;;  can.
;;;;
;;;;  This is implemented by a pair of generic functions,
;;;;  autoaxis-guess-index and autoaxis-generate, which should
;;;;  specialize on mapping and axis types.  The density of marks is
;;;;  indexed by an integer: the first function provides a "good"
;;;;  guess and the allowed minimum and maximum (if any, otherwise
;;;;  nil), while the second one generates the marks for a particular
;;;;  integer.  The axis generation mechanism simply explores the
;;;;  vicinity (see *autoaxis-exploration*) and pick the best axis.

(defun calculate-maximum-overlap (mapping axis extent
				  &key (context *context*)
				  (value-if-undefined nil))
  "Calculate the maximum overlap between marks of an axis.  The
  appropriate label style needs to be set on context.  Extent is
  either width or height.  Ideally, overlap is negative, which means
  that there is space between the marks."
  (let ((pos-widths
	 (iter
	   (for position :in (axis-positions axis))
	   (for mark :in (axis-marks axis))
	   (when mark
	     (bind ((pos (map-coordinate mapping position :half))
		    ((:values nil nil width height nil nil)
		     (text-extents mark context))
		    (width (ecase extent
			    (:width width)
			    (:height height))))
	       (collect (list pos width)))))))
    (if (<= (length pos-widths) 1)
	;; undefined
	value-if-undefined
	;; take differences
	(iter
	  (for (pos width) :in pos-widths)
	  (for pos-p :previous pos :initially nil)
	  (for width-p :previous width :initially nil)
	  (when pos-p
	    (let* ((difference (abs (- pos pos-p)))
		   (overlap (- (/ (+ width width-p) 2) difference)))
              ;; (format t "pos=~a  pos-p=~a  width=~a  width-p=~a  diff=~a  overlap=~a~% "
              ;;         pos pos-p width width-p difference overlap)
	      (maximizing overlap)))))))
	     
(defgeneric autoaxis-guess-index (mapping autoaxis)
  (:documentation "A guess for the density index (an integer).
Return (values guess min max), where the latter two are the allowed
minimum and maximum (nil if not constrained)."))

(defgeneric autoaxis-generate (mapping autoaxis index)
  (:documentation "Generate axis automatically, using mapping and the
  density index."))

(defparameter *autoaxis-exploration* 5
  "explore this many indices in both directions")

(defparameter *autoaxis-minimum-text-distance* 1
  "minimum mark distance in capital letter height (see capital-letter-height)")

(defun autoaxis-pick-best (mapping autoaxis extent &optional
			   (context *context*))
  (declare (optimize debug))
  "Pick the best fitting autoaxis.  Mark style needs to be set on
context.  Extent is :width or :height."
  ;; if the domain is very narrow, just return a single mark
  (let* ((domain (domain mapping))
         (width (width domain)))
    (when (or (zerop width) (<= (/ (width domain)
                                   (max (abs (left domain)) (abs (right domain))))
                                1e-10)) ; !!! ? relative precision
      (let ((left (left domain)))
	(return-from autoaxis-pick-best
	  (make-instance 'axis :positions (list left)
			 :marks (list (format nil "~f" left)))))))
  (with-context (context)
    (bind ((allowed-maximum-overlap (- (* *autoaxis-minimum-text-distance* 
                                          (capital-letter-height))))
           ((:values index-guess index-min index-max)
            (autoaxis-guess-index mapping autoaxis))
           ((:values smallest-index largest-index)
            (flet ((apply-if (function value1 value2)
                     ;; used for constraining conditional on boundary
                     (if value1
                         (funcall function value1 value2)
                         value2)))
              (values (apply-if #'max index-min (- index-guess *autoaxis-exploration*))
                      (apply-if #'min index-max (+ index-guess *autoaxis-exploration*))))))
      (flet ((unit-mapping (x)
	       ;; map [0,inf) to [0,1), for badness calculations.  the
	       ;; only thing that matters is that it preserves
	       ;; ordering
	       (/ x (1+ x))))
	(iter
	  (for index :from smallest-index :to largest-index)
	  (for axis := (autoaxis-generate mapping autoaxis index))
	  (for overlap := (calculate-maximum-overlap mapping axis extent))
	  (for badness :=
	       ;; in order of decreasing badness, mapped to positive intervals
	       (cond
		 ;; no marks at all, extremely bad
		 ((null (axis-marks axis))
		  4)
		 ;; overlapping marks, intolerable
		 ((and overlap (plusp overlap))
		  (+ 3 (unit-mapping overlap)))
		 ;; single mark: first acceptable, but maybe we can do better
		 ((not overlap)
		  2)
		 ;; no overlap, but not enough space
		 ((< allowed-maximum-overlap overlap 0)
		  (1+ (unit-mapping (- overlap allowed-maximum-overlap))))
		 ;; enough space, lets pack them as tight as possible
		 ((<= overlap allowed-maximum-overlap)
		  (unit-mapping (- allowed-maximum-overlap overlap)))))
	  ;; (format t "~&*************~%~
          ;;            index=~a  axis=~a~%overlap=~a  badness=~a  max-ov=~a~%"
          ;;            index axis overlap badness allowed-maximum-overlap)
	  (finding axis :minimizing badness))))))

(defun axis-set-style-expand (mapping axis axis-style extent &optional
			      (context *context*))
  "Set style and return expanded (if necessary) axis."
  (with-sync-lock (context)
    (with-context (context)
      (with-slots (axis-padding font-style line-style tick-length tick-padding
				title-padding) axis-style
	;; set styles
	(set-style line-style)
	(set-style font-style)
	;; expand autoaxis when necessary
	(if (typep axis 'axis)
	    axis
	    (autoaxis-pick-best mapping axis extent))))))

(defun text-rotation-angle (direction)
  "Return the rotation angle of text from the given direction (:right
  or :normal, :up, or :down)."
  (ecase direction
    ((:right :normal) 0)
    (:down (* pi 1/2))
    (:up (* pi 3/2))))

(defun vertical-axis (frame mapping axis title axis-style
		      left-axis-p)
  (with-slots (context horizontal-interval vertical-interval) frame
    (with-context (context)
      (with-sync-lock (context)
	(with-slots (axis-padding mark-direction tick-length
				  tick-padding title-padding) axis-style
	  (bind ((axis (axis-set-style-expand mapping axis axis-style
					      (ecase mark-direction
						((:up :down) :width)
						(otherwise :height))))
		 ((:values start direction mark-x-align
			   title-x-align title-angle)
		  (if left-axis-p
		      (values (right horizontal-interval) -1 1
			      0  (text-rotation-angle :up))
		      (values (left horizontal-interval) 1 0
			      1 (text-rotation-angle :down))))
		 (tick-start (+ start (* direction axis-padding)))
		 (tick-end (+ tick-start (* direction tick-length)))
		 (mark-x (+ tick-end (* direction tick-padding))))
	    ;; axis line
	    (segment tick-start (left vertical-interval)
		     tick-start (right vertical-interval))
	    ;; axis ticks and marks
	    (let ((angle (text-rotation-angle mark-direction)))
	      (iter
		(for mark :in (axis-marks axis))
		(for position :in (axis-positions axis))
		(for y := (map-coordinate mapping position))
		(segment tick-start y tick-end y)
		(aligned-text mark-x y mark
			      :x-align mark-x-align :y-align 0.5
			      :angle angle))
	    ;; draw axis title
	    (aligned-text (- (funcall (if left-axis-p
					   #'left
					   #'right)
				       horizontal-interval)
			      (* direction title-padding))
			   (interval-midpoint vertical-interval) title
			   :x-align title-x-align
			   :angle title-angle))))))))

(defun left-axis (frame mapping axis title 
		  &optional (axis-style *default-left-axis-style*))
  "Draw axis as a left axis in frame with given style."
  (vertical-axis frame mapping axis title axis-style t))

(defun right-axis (frame mapping axis title 
		  &optional (axis-style *default-right-axis-style*))
  "Draw axis as a right axis in frame with given style."
  (vertical-axis frame mapping axis title axis-style nil))

(defun horizontal-axis (frame mapping axis title axis-style
		      bottom-axis-p)
  (with-slots (context horizontal-interval vertical-interval) frame
    (with-context (context)
      (with-sync-lock (context)
	(with-slots (axis-padding mark-direction tick-length
				  tick-padding title-padding) axis-style
	  (bind ((axis (axis-set-style-expand mapping axis axis-style
					      (case mark-direction
						((:up :down) :height)
						(otherwise :width))))
		 ((:values start direction mark-y-align
			   title-y-align title-angle)
		  (if bottom-axis-p
		      (values (right vertical-interval) 1 0
			      1 (text-rotation-angle :right))
		      (values (left vertical-interval) -1 1
			      0 (text-rotation-angle :right))))
		 (tick-start (+ start (* direction axis-padding)))
		 (tick-end (+ tick-start (* direction tick-length)))
		 (mark-y (+ tick-end (* direction tick-padding))))
	    ;; axis line
	    (segment (left horizontal-interval) tick-start
		     (right horizontal-interval) tick-start)
	    ;; axis ticks and marks
	    (let ((angle (text-rotation-angle mark-direction)))
	      (iter
		(for mark :in (axis-marks axis))
		(for position :in (axis-positions axis))
		(for x := (map-coordinate mapping position))
		(segment x tick-start x tick-end)
		(aligned-text x mark-y mark
			      :x-align 0.5 :y-align mark-y-align
			      :angle angle))
	    ;; draw axis title
	    (aligned-text (interval-midpoint horizontal-interval)
			  (- (funcall (if bottom-axis-p
					  #'left
					  #'right)
				      vertical-interval)
			     (* direction title-padding))
			  title
			  :y-align title-y-align
			  :angle title-angle))))))))

(defun bottom-axis (frame mapping axis title 
		  &optional (axis-style *default-horizontal-axis-style*))
  "Draw axis as a bottom axis in frame with given style."
  (horizontal-axis frame mapping axis title axis-style t))

(defun top-axis (frame mapping axis title 
		  &optional (axis-style *default-horizontal-axis-style*))
  "Draw axis as a top axis in frame with given style."
  (horizontal-axis frame mapping axis title axis-style nil))

;;;;  Specific axis types
;;;;

;;;;  Autogeneration for linear axes
;;;;
;;;;  Indexing is on the divisor of the stepsize: ...,0,1,2,3,... for
;;;;  ...,1,2,5,10,..., to infinity in both directions.

(defun format-exponential-mark (x exponent digits)
  "Return a formatted version of x, with given exponent and number of
digits after the decimal dot.  If digits <= 0, there is no decimal dot."
  (let ((mantissa (/ x (expt 10 exponent))))
    (if (plusp digits)
	(format nil "~,vfe~d" digits mantissa exponent)
	(format nil "~de~d" (round mantissa) exponent))))

(defun linear-autoaxis-marks (domain index &key (include-domain-p nil)
			      (min-exponent -5) (max-exponent 5))
  "Marks for a linear axis."
  (bind (((:values exp10 step10) (floor index 3))
	 (step (* (expt 10 exp10) (ecase step10
				    (0 1)
				    (1 2)
				    (2 5))))
	 (positive-p (positive-interval-p domain))
	 (reverse-p (if positive-p	; (xor positive-p include-domain-p)
			(not include-domain-p)
			include-domain-p))
	 ;; endpoints
	 (left-i (funcall (if reverse-p
			      #'ceiling
			      #'floor)
			  (rationalize (left domain)) step))
	 (right-i (funcall (if reverse-p
			       #'floor
			       #'ceiling)
			   (rationalize (right domain)) step))
	 ;; determines exponent
	 (exponent (floor (log (max (abs (left domain)) 
				    (abs (right domain))) 10)))
	 ;; formatting
	 (formatter
	  (cond
	    ;; digits after the decimal dot, scientific notation
	    ((and min-exponent (< exponent min-exponent))
	     (let ((digits (- exponent exp10)))
	       (format t "digits=~d~%" digits)
	       (lambda (x)
		 (format-exponential-mark x exponent digits))))
	     ;; large exponent, scientific notation
	    ((and max-exponent (< max-exponent exponent))
	     (let ((digits (- exponent exp10)))
	       (lambda (x)
		 (format-exponential-mark x exponent digits))))
	    ;; in between, normal formatting
	    (t
	     (let ((digits (max 0 (- exp10))))
	       (if (plusp digits)
		   (lambda (x)
		     (format nil "~,vf" digits x))
		   (lambda (x)
		     (format nil "~d" x))))))))
    ;; generate marks
    (if positive-p
	(iter
	  (for i :from left-i :to right-i)
	  (for pos := (* i step))
	  (collect pos :into positions)
	  (collect (funcall formatter pos) :into marks)
	  (finally
	   (return (make-instance 'axis :positions positions :marks marks))))
	(iter
	  (for i :from left-i :downto right-i)
	  (for pos := (* i step))
	  (collect pos :into positions)
	  (collect (funcall formatter pos) :into marks)
	  (finally
	   (return (make-instance 'axis :positions positions :marks marks)))))))

(defmethod autoaxis-guess-index ((mapping linear-mapping) autoaxis)
  (* (floor (log (width (domain mapping)) 10)) 3))

(defmethod autoaxis-generate ((mapping linear-mapping) autoaxis index)
  (linear-autoaxis-marks (domain mapping) index))
  
;;;; test cases --- should eventually wind up in unit testing
	 
;; (linear-autoaxis-marks (make-interval (+ 1e-6 1e-9) (+ 1e-6 1e-8)) -28)
;; (linear-autoaxis-marks (make-interval (+ 1e10 1e7) (+ 1e10 5e7)) 16)



;;;;  Autogeneration for log axes
;;;;
;;;;  The default arrangement is to have powers of 10 on the axis, in
;;;;  the form of 1e0, 1e1, etc.  Indexing is from 1: an index of n
;;;;  will have marks at every 10^n units.  Indexes below 1 are
;;;;  interpreted as 1.

;; !!!! this code section needs to be finished

;; (defmethod autoaxis-guess-index ((mapping log-mapping) autoaxis)
;;   (with-slots (domain) mapping
;;     (with-slots (left right) domain
;;       ;; The expression + *autoaxis-exploration* would put a mark
;;       ;; everywhere possible
;;       (- (ceiling (log (- (log right 10) (log left 10)) 2))
;; 	 *autoaxis-exploration*))))

;; (defmethod autoaxis-generate ((mapping log-mapping) autoaxis index)
;;   (with-slots (domain) mapping
;;     (let 
