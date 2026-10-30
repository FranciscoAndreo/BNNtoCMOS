;-------------------------------------------------------------------------------
; NeuralNetwork_PIPELINED.il -- PIPELINED network (level 1): the layers of
; LAYERS in cascade, NNFILE.
;
; Output OA_<f>_<col> of layer i-1 drives input D_IA_<f>_<col> of layer i
; through net Net<i-1>_<f>_<col>. The cell has a pin for everything else, so it
; can be placed in a testbench:
;   IN_<z>_<col>         image row inputs (first layer)
;   OUT_<f>_<col>        outputs of the last layer
;   WL<i>_<z>_<f>_<k>    weight word lines of layer i
;   B_<i>_<f>            batch-norm thresholds of layer i
;   shared control and supply pins (NN_CONTROL).
;-------------------------------------------------------------------------------
; Working variables are local so the caller's variables are left untouched.
let( (cvNN NN_CONTROL nnPins xNN lastLayer F C LAYER_NAME LAYER_SYMBOL capa LABEL testPins)
	deleteSchematic(LIBNAME NNFILE "schematic")
	cvNN = dbOpenCellViewByType( LIBNAME NNFILE "schematic" "schematic" "w" )

	NN_CONTROL = '(("VDDA" "inputOutput") ("VSSA" "inputOutput")
		("SEL_0" "input") ("SEL_1" "input") ("SEL_2" "input") ("MULTIPLY" "input") ("RST" "input") ("AVG" "input")
		("WL_IA_0" "input") ("WL_IA_1" "input") ("WL_IA_2" "input") ("PRECHG_W" "input") ("PRECHG_IA" "input")
		("WR_W_EN" "input") ("WR_IA_ENABLE" "input") ("SEL_IA_W" "input") ("D_W" "input"))
	nnPins = reverse(NN_CONTROL)
	xNN = 0
	lastLayer = length(LAYERS)-1

	for(i 0 lastLayer
		F = nth(i LAYERS)
		C = if(i == 0 then INPUT_DIMENSION else nth(i-1 LAYERS))
		sprintf(LAYER_NAME "%s_%d" LAYERFILE F)
		println(LAYER_NAME)
		LAYER_SYMBOL = dbOpenCellViewByType( LIBNAME LAYER_NAME "symbol" "" "r" )
		capa = schCreateInst( cvNN LAYER_SYMBOL sprintf(nil "LAYER%d" i) xNN:0 "R0" )
		xNN = xNN + 4 + caadr(LAYER_SYMBOL~>bBox) - caar(LAYER_SYMBOL~>bBox)

		foreach(sig NN_CONTROL DrawLabelName(capa car(sig) car(sig) cvNN))
		when( b2cBatchNormModel()  ; EN of the behavioural batch norm, one per layer
			sprintf(LABEL "EN_%d" i)
			DrawLabelName(capa "EN" LABEL cvNN)
			nnPins = cons(list(LABEL "input") nnPins))
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
			for(col 0 IMAGE_WIDTH-1
				if(i == 0 then
					sprintf(LABEL "IN_%d_%d" z col)
					nnPins = cons(list(LABEL "input") nnPins)
				else
					sprintf(LABEL "Net%d_%d_%d" i-1 z col))
				DrawLabelName(capa sprintf(nil "D_IA_%d_%d" z col) LABEL cvNN)))
		for(f 0 F-1
			for(col 0 IMAGE_WIDTH-1
				if(i == lastLayer then
					sprintf(LABEL "OUT_%d_%d" f col)
					nnPins = cons(list(LABEL "output") nnPins)
				else
					sprintf(LABEL "Net%d_%d_%d" i f col))
				DrawLabelName(capa sprintf(nil "OA_%d_%d" f col) LABEL cvNN)))
	)

	b2cPlacePinsLeft(cvNN reverse(nnPins))
	testPins = schSchemToPinList( LIBNAME NNFILE "schematic")
	schPinListToSymbol( LIBNAME NNFILE "symbol" testPins )
	schCheck(cvNN)
	dbSave(cvNN)
	dbClose(cvNN)
)
