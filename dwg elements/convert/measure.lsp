(defun objbb (obj / mn mx r)
  (if (vl-catch-all-error-p
        (setq r (vl-catch-all-apply
                  (function (lambda () (vla-getboundingbox obj 'mn 'mx))))))
    nil
    (progn
      (setq mn (vlax-safearray->list mn) mx (vlax-safearray->list mx))
      (list mn mx)
    )
  )
)

(defun bbstr (bb)
  (if bb
    (strcat
      (rtos (nth 0 (car bb)) 2 3) "," (rtos (nth 1 (car bb)) 2 3) "," (rtos (nth 2 (car bb)) 2 3)
      "  ->  "
      (rtos (nth 0 (cadr bb)) 2 3) "," (rtos (nth 1 (cadr bb)) 2 3) "," (rtos (nth 2 (cadr bb)) 2 3))
    "NO-BBOX"
  )
)

(defun typecount (mask / ss)
  (if (setq ss (vl-catch-all-apply '(lambda () (ssget "_X" (list (cons 0 mask))))))
    (itoa (sslength ss))
    "ERR"
  )
)

(defun meas (outpath / f doc ms n i obj tp nm bb blk)
  (vl-load-com)
  (setq f (open outpath "w"))
  (setq doc (vla-get-activedocument (vlax-get-acad-object)))
  (setq ms (vla-get-modelspace doc))
  (write-line (strcat "MODELCOUNT=" (itoa (vla-get-count ms))) f)

  (setq mn (getvar "EXTMIN") mx (getvar "EXTMAX"))
  (write-line (strcat "RAW EXTMIN=" (rtos (nth 0 mn) 2 4) "," (rtos (nth 1 mn) 2 4) "," (rtos (nth 2 mn) 2 4)) f)
  (write-line (strcat "RAW EXTMAX=" (rtos (nth 0 mx) 2 4) "," (rtos (nth 1 mx) 2 4) "," (rtos (nth 2 mx) 2 4)) f)

  (vl-catch-all-apply '(lambda () (command "_.ZOOM" "_.E")))
  (setq mn (getvar "EXTMIN") mx (getvar "EXTMAX"))
  (write-line (strcat "ZOOMED EXTMIN=" (rtos (nth 0 mn) 2 4) "," (rtos (nth 1 mn) 2 4) "," (rtos (nth 2 mn) 2 4)) f)
  (write-line (strcat "ZOOMED EXTMAX=" (rtos (nth 0 mx) 2 4) "," (rtos (nth 1 mx) 2 4) "," (rtos (nth 2 mx) 2 4)) f)

  (write-line "--- UCS ---" f)
  (setq mn (getvar "UCSORG"))
  (write-line (strcat "UCSORG=" (rtos (nth 0 mn) 2 4) "," (rtos (nth 1 mn) 2 4) "," (rtos (nth 2 mn) 2 4)) f)
  (write-line (strcat "INSUNITS=" (itoa (getvar "INSUNITS"))) f)

  (write-line "--- TYPE COUNTS ---" f)
  (foreach mask '("INSERT" "*3DSOLID" "BODY" "SOLID" "3DFACE" "MESH"
                  "LINE" "LWPOLYLINE" "POLYLINE" "MLINE" "CIRCLE" "ARC"
                  "TEXT,MTEXT" "DIMENSION" "HATCH" "ACAD_PROXY_ENTITY" "PROXY"
                  "ATTDEF" "REGION" "SURFACE")
    (write-line (strcat mask " : " (typecount mask)) f))

  (write-line "--- BLOCK TABLE ---" f)
  (setq blk (tblnext "BLOCK" T))
  (while blk
    (if (/= (substr (cdr (assoc 2 blk)) 1 1) "*")
      (write-line (strcat "BLOCK " (cdr (assoc 2 blk))
                          " ents=" (itoa (defcount (cdr (assoc 2 blk))))
                          (if (cdadr (assoc 3 blk)) (strcat " xr=" (cdadr (assoc 3 blk))) "")) f))
    (setq blk (tblnext "BLOCK"))
  )

  (write-line "--- TOP-LEVEL ITEMS (first 400) ---" f)
  (setq n (vla-get-count ms) i 0)
  (while (and (< i n) (< i 400))
    (setq obj (vla-item ms i) tp (vla-get-objectname obj))
    (setq nm "")
    (cond
      ((wcmatch tp "*INSERT")
       (setq nm (vl-catch-all-apply '(lambda () (strcat " BLOCK=" (vla-get-effectivename obj))))))
      ((wcmatch tp "*Attribute*") (setq nm (vl-catch-all-apply '(lambda () (strcat " TAG=" (vla-get-tagstring obj))))))
      ((or (wcmatch tp "*Text*") (wcmatch tp "*MText*"))
       (setq nm (vl-catch-all-apply '(lambda () (strcat " TXT=" (substr (vla-get-textstring obj) 1 60))))))
    )
    (if (vl-catch-all-error-p nm) (setq nm ""))
    (write-line (strcat "ITEM " (itoa i) " " tp nm " BOX=" (bbstr (objbb obj))) f)
    (setq i (1+ i))
  )

  (close f)
  (princ (strcat "\nMEAS-DONE " outpath "\n"))
)