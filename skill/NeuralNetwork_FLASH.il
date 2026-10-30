;-------------------------------------------------------------------------------
; NeuralNetwork_FLASH.il -- FLASH network (level 1): the layers of LAYERS in
; cascade, NNFILE.
;
; Output OA_<f>_<pixel> of layer i-1 drives input IA_<f>_<row>_<col> of layer i
; (pixel = row*IMAGE_WIDTH + col) through net Net<i-1>_<f>_<pixel>. The cell
; has a pin for everything else, so it can be placed in a testbench:
;   IN_<z>_<row>_<col>   image inputs (first layer)
;   OUT_<f>_<pixel>      outputs of the last layer
;   WL<i>_<z>_<f>_<k>    weight word lines of layer i
;   B_<i>_<f>            batch-norm thresholds of layer i
;   shared control and supply pins (NN_CONTROL).
;-------------------------------------------------------------------------------
; Working variables are local so the caller's variables are left untouched.
let( (cvNN NN_CONTROL nnPins xNN lastLayer F C LAYER_NAME LAYER_SYMBOL capa LABEL testPins)
	deleteSchematic(LIBNAME NNFILE "schematic")
	cvNN = dbOpenCellViewByType( LIBNAME NNFILE "schematic" "schematic" "w" )

	NN_CONTROL = '(("VDDA" "inputOutput") ("VSSA" "inputOutput")
		("MULTIPLY" "input") ("RST" "input") ("AVG" "input") ("D" "input") ("PRECHG_W" "input"))
	nnPins = reverse(NN_CONTROL)
	xNN = 0
	lastLayer = length(LAYERS)-1

	for(i 0 lastLayer
		F = nth(i LAYERS)
		C = if(i == 0 then INPUT_DIMENSION else nth(i-1 LAYERS))
		sprintf(LAYER_NAME "%s_%d" LAYERFILE F)
		LAYER_SYMBOL = dbOpenCellViewByType( LIBNAME LAYER_NAME "symbol" "" "r" )
		capa = schCreateInst( cvNN LAYER_SYMBOL sprintf(nil "LAYER%d" i) xNN:0 "R0" )
		xNN = xNN + 4 + caadr(LAYER_SYMBOL~>bBox) - caar(LAYER_SYMBOL~>bBox)

		foreach(sig NN_CONTROL DrawLabelName(capa car(sig) car(sig) cvNN))
		for(f 0 F-1
			sprintf(LABEL "B_%d_%d" i f)
			DrawLabelName(capa sprintf(nil "B_%d" f) LABEL cvNN)
			nnPins = cons(list(LABEL "input") nnPins)
			for(z 0 C-1
				for(k 0 KERNEL_SIZE-1
					sprintf(LABEL "WL%d_%d_%d_%d" i z f k)
					DrawLabelName(capa sprintf(nil "WL_%d_%d_%d" z f k) LABEL cvNN)
					nnPins = cons(list(LABEL "input") nnPins))))
		for(z 0 C-1
			for(r 0 IMAGE_HEIGHT-1
				for(c 0 IMAGE_WIDTH-1
					if(i == 0 then
						sprintf(LABEL "IN_%d_%d_%d" z r c)
						nnPins = cons(list(LABEL "input") nnPins)
					else
						sprintf(LABEL "Net%d_%d_%d" i-1 z r*IMAGE_WIDTH+c))
					DrawLabelName(capa sprintf(nil "IA_%d_%d_%d" z r c) LABEL cvNN))))
		for(f 0 F-1
			for(p 0 IMAGE_WIDTH*IMAGE_HEIGHT-1
				if(i == lastLayer then
					sprintf(LABEL "OUT_%d_%d" f p)
					nnPins = cons(list(LABEL "output") nnPins)
				else
					sprintf(LABEL "Net%d_%d_%d" i f p))
				DrawLabelName(capa sprintf(nil "OA_%d_%d" f p) LABEL cvNN)))
	)

	b2cPlacePinsLeft(cvNN reverse(nnPins))
	testPins = schSchemToPinList( LIBNAME NNFILE "schematic")
	schPinListToSymbol( LIBNAME NNFILE "symbol" testPins )
	schCheck(cvNN)
	dbSave(cvNN)
	dbClose(cvNN)
)
