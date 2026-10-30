;-------------------------------------------------------------------------------
; Layer_FLASH.il -- FLASH layer (level 2): layerFlash(C F) builds
; <LAYERFILE>_<F> with F filters over a C-channel input.
;
; One channel instance per (input channel z, filter f). The C channels of filter
; f share their outputs VAVG_<f>_<pixel>, which averages them (the 3D
; convolution, level 3). The batch-norm cell turns them into the binary outputs
; OA_<f>_<pixel> (pixel = row*IMAGE_WIDTH + col) using the threshold input B_<f>.
; Inputs are IA_<z>_<row>_<col>, weights WL_<z>_<f>_<k>.
;-------------------------------------------------------------------------------
procedure( layerFlash(DIMENSION_INPUT, FILTERS)

sprintf(BATCH_X "%s_%d" BATCHFILE FILTERS)
sprintf(layerName "%s_%d" LAYERFILE FILTERS)
BatchFlash(DIMENSION_INPUT, FILTERS)
deleteSchematic(LIBNAME layerName "schematic")
cvLayer = dbOpenCellViewByType( LIBNAME layerName "schematic" "schematic" "a" )
CHANNEL_SYMBOL = dbOpenCellViewByType( LIBNAME CHANNELFILE "symbol" "" "r" )
BATCH_SYMBOL = dbOpenCellViewByType( LIBNAME BATCH_X "symbol" "" "r" )

layerPins = list(
	list("VSSA" "inputOutput") list("VDDA" "inputOutput")
	list("MULTIPLY" "input") list("RST" "input") list("AVG" "input") list("D" "input") list("PRECHG_W" "input"))
inputPins = nil  ; collected in reverse order
outputPins = nil

; Channels on a grid of pitch (3.5, 4.5 IMAGE_WIDTH), or wider for a larger
; channel symbol (see layerPipeline).
pitch = b2cChannelPitch(CHANNEL_SYMBOL 3.5 IMAGE_WIDTH*4.5)
Batch = schCreateInst( cvLayer BATCH_SYMBOL nil -5:0 "R0" )
for(z 0 DIMENSION_INPUT-1
for(i 0 FILTERS-1
	Channel = schCreateInst( cvLayer CHANNEL_SYMBOL nil car(pitch)*i:z*-cadr(pitch) "R0" )

	for(j 0 IMAGE_WIDTH*IMAGE_HEIGHT-1
		sprintf(PIN "VAVG_%d" j)
		sprintf(LABEL "VAVG_%d_%d" i j)
		DrawLabelName(Channel,PIN,LABEL, cvLayer)
		DrawLabelName(Batch,LABEL,LABEL, cvLayer)
		sprintf(LABEL "OA_%d_%d" i j)
		DrawLabelName(Batch,LABEL,LABEL, cvLayer)
		when(z == 0 outputPins = cons(list(LABEL "output") outputPins))
	)
	for(r 0 IMAGE_HEIGHT-1
		for(c 0 IMAGE_WIDTH-1
			sprintf(PIN "IA_%d_%d_%d" z r c)
			sprintf(PIN_orig "IA_%d_%d" r c)
			when(i == 0 inputPins = cons(list(PIN "input") inputPins))
			DrawLabelName(Channel,PIN_orig,PIN, cvLayer)
		)
	)
	for(j 0 KERNEL_SIZE-1
		sprintf(PIN "WL%d" j)
		sprintf(LABEL "WL_%d_%d_%d" z i j)
		DrawLabelName(Channel,PIN,LABEL, cvLayer)
		inputPins = cons(list(LABEL "input") inputPins)
	)
	when(z == 0
		sprintf(s "B_%d" i)
		DrawLabelName(Batch,s,s, cvLayer)
		inputPins = cons(list(s "input") inputPins))
)
)

DrawLabelCommon(CHANNELFILE,"AVG", cvLayer)
DrawLabelCommon(CHANNELFILE,"RST", cvLayer)
DrawLabelCommon(CHANNELFILE,"MULTIPLY", cvLayer)
DrawLabelCommon(CHANNELFILE,"PRECHG_W", cvLayer)
DrawLabelCommon(CHANNELFILE,"D", cvLayer)
DrawLabelCommon(CHANNELFILE,"VSSA", cvLayer)
DrawLabelCommon(CHANNELFILE,"VDDA", cvLayer)
DrawLabelCommon(BATCH_X,"VSSA", cvLayer)
DrawLabelCommon(BATCH_X,"VDDA", cvLayer)
when( b2cBatchNormModel() DrawLabelCommon(BATCH_X "RST" cvLayer))

b2cPlacePinsLeft(cvLayer append(layerPins append(reverse(inputPins) reverse(outputPins))))

testPins = schSchemToPinList( LIBNAME layerName "schematic")
schPinListToSymbol( LIBNAME layerName "symbol" testPins )
schCheck(cvLayer)
dbSave(cvLayer)
dbClose(cvLayer)
)
