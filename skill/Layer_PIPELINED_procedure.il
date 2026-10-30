;-------------------------------------------------------------------------------
; Layer_PIPELINED_procedure.il -- PIPELINED layer (level 2): layerPipeline(C F)
; builds <LAYERFILE>_<F> with F filters over a C-channel input.
;
; One channel instance per (input channel z, filter f). The C channels of filter
; f share their outputs VAVG_<f>_<col>, which averages them (the 3D
; convolution, level 3). The batch-norm cell turns them into the binary outputs
; OA_<f>_<col> using the threshold input B_<f>. Inputs are D_IA_<z>_<col>,
; weights WL_<z>_<f>_<k>.
;-------------------------------------------------------------------------------
procedure( layerPipeline(DIMENSION_INPUT, FILTERS)

BatchPipeline(DIMENSION_INPUT, FILTERS)
sprintf(BATCH_X "%s_%d" BATCHFILE FILTERS)
sprintf(layerName "%s_%d" LAYERFILE FILTERS)
deleteSchematic(LIBNAME layerName "schematic")
cvLayer = dbOpenCellViewByType( LIBNAME layerName "schematic" "schematic" "a" )
CHANNEL_SYMBOL = dbOpenCellViewByType( LIBNAME CHANNELFILE "symbol" "" "r" )
BATCH_SYMBOL = dbOpenCellViewByType( LIBNAME BATCH_X "symbol" "" "r" )

layerPins = list(
	list("VSSA" "inputOutput") list("VDDA" "inputOutput")
	list("SEL_0" "input") list("SEL_1" "input") list("SEL_2" "input")
	list("MULTIPLY" "input") list("RST" "input") list("AVG" "input")
	list("WL_IA_0" "input") list("WL_IA_1" "input") list("WL_IA_2" "input")
	list("PRECHG_W" "input") list("PRECHG_IA" "input") list("WR_W_EN" "input")
	list("WR_IA_ENABLE" "input") list("SEL_IA_W" "input") list("D_W" "input"))
when( b2cBatchNormModel() layerPins = append(layerPins list(list("EN" "input"))))
inputPins = nil  ; collected in reverse order
outputPins = nil

; Channels on a grid of pitch (3.5, 6), or wider for a larger channel symbol
; (wide images): a pitch smaller than the symbol overlaps the channels of
; consecutive input channels, and their label stubs land on each other's pins.
pitch = b2cChannelPitch(CHANNEL_SYMBOL 3.5 6)
y = 1
Batch = schCreateInst( cvLayer BATCH_SYMBOL nil -5:0 "R0" )
for(z 0 DIMENSION_INPUT-1
for(i 0 FILTERS-1
	Channel = schCreateInst( cvLayer CHANNEL_SYMBOL nil car(pitch)*i:y "R0" )
	for(j 0 IMAGE_WIDTH-1
		sprintf(PIN "VAVG_%d" j)
		sprintf(LABEL "VAVG_%d_%d" i j)
		DrawLabelName(Channel,PIN,LABEL, cvLayer)
		DrawLabelName(Batch,LABEL,LABEL, cvLayer)
		sprintf(LABEL "OA_%d_%d" i j)
		DrawLabelName(Batch,LABEL,LABEL, cvLayer)
		when(z == 0 outputPins = cons(list(LABEL "output") outputPins))

		sprintf(PIN "D_IA_%d" j)
		sprintf(LABEL "D_IA_%d_%d" z j)
		DrawLabelName(Channel,PIN,LABEL, cvLayer)
		when(i == 0 inputPins = cons(list(LABEL "input") inputPins))
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
y = y - cadr(pitch)
)
DrawLabelCommon(CHANNELFILE,"AVG", cvLayer)
DrawLabelCommon(CHANNELFILE,"RST", cvLayer)
DrawLabelCommon(CHANNELFILE,"MULTIPLY", cvLayer)
DrawLabelCommon(CHANNELFILE,"PRECHG_IA", cvLayer)
DrawLabelCommon(CHANNELFILE,"PRECHG_W", cvLayer)
DrawLabelCommon(CHANNELFILE,"D_W", cvLayer)
DrawLabelCommon(CHANNELFILE,"WR_IA_ENABLE", cvLayer)
DrawLabelCommon(CHANNELFILE,"WR_W_EN", cvLayer)
DrawLabelCommon(CHANNELFILE,"SEL_IA_W", cvLayer)

DrawLabelCommon(CHANNELFILE,"VSSA", cvLayer)
DrawLabelCommon(CHANNELFILE,"VDDA", cvLayer)
DrawLabelCommon(BATCH_X,"VSSA", cvLayer)
DrawLabelCommon(BATCH_X,"VDDA", cvLayer)
when( b2cBatchNormModel()
	DrawLabelCommon(BATCH_X "RST" cvLayer)
	DrawLabelCommon(BATCH_X "EN" cvLayer))

DrawLabelCommon(CHANNELFILE,"WL_IA_0", cvLayer)
DrawLabelCommon(CHANNELFILE,"WL_IA_1", cvLayer)
DrawLabelCommon(CHANNELFILE,"WL_IA_2", cvLayer)
DrawLabelCommon(CHANNELFILE,"SEL_0", cvLayer)
DrawLabelCommon(CHANNELFILE,"SEL_1", cvLayer)
DrawLabelCommon(CHANNELFILE,"SEL_2", cvLayer)

b2cPlacePinsLeft(cvLayer append(layerPins append(reverse(inputPins) reverse(outputPins))))

testPins = schSchemToPinList( LIBNAME layerName "schematic")
schPinListToSymbol( LIBNAME layerName "symbol" testPins )
schCheck(cvLayer)
dbSave(cvLayer)
dbClose(cvLayer)
)
