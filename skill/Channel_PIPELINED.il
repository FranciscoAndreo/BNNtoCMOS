;-------------------------------------------------------------------------------
; Channel_PIPELINED.il -- PIPELINED channel (level 4): IMAGE_WIDTH masks that
; process one image row per cycle, CHANNELFILE.
;
; Mask w loads input pixel D_IA_<w> into its row buffer and drives VAVG_<w>.
; Its buffered rows C_<w>_<0..2> are shared with the masks w-1 and w+1 (VSSA
; at the image border), which gives each mask its 3x3 window. Then builds the
; batch-norm and layer cells and the network.
;-------------------------------------------------------------------------------
deleteSchematic(LIBNAME CHANNELFILE "schematic")
cvChannel = dbOpenCellViewByType( LIBNAME CHANNELFILE "schematic" "schematic" "a" )
MASK_SYMBOL = dbOpenCellViewByType( LIBNAME MASKFILE "symbol" "" "r" )

x = 1
y = 1
temp = 0
for( i 1 IMAGE_WIDTH
		mascara = schCreateInst( cvChannel MASK_SYMBOL nil 2.5*x:y "R0" )
		DrawLabelID(mascara,"VAVG","VAVG_", i-1, cvChannel)
		DrawLabelID(mascara,"D_IA","D_IA_", temp, cvChannel)
		temp = temp + 1
		DrawLabelName(mascara,"WR_W_ENABLE","WR_W_EN", cvChannel)
		; Buffered rows: C_0..2 of this column, C_3..5 of the left and C_6..8
		; of the right neighbour (VSSA beyond the image border).
		w = i-1
		for(k 0 KERNEL_SIZE-1
			col = nth(quotient(k 3) list(w w-1 w+1))
			if(col >= 0 && col < IMAGE_WIDTH
				then sprintf(s "C_%d_%d" col remainder(k 3))
				else s = "VSSA")
			DrawLabelName(mascara, sprintf(nil "C_%d" k), s, cvChannel))
		x += 1.5
		if(x/1.5 >= IMAGE_WIDTH 
			then y -=5
			x = 1
			)

	)
for(x 0 KERNEL_SIZE-1
		sprintf(LABEL_NAME "WL%d" x)
		DrawLabelCommon(MASKFILE,LABEL_NAME, cvChannel)
)

for(x 0 fix(sqrt(KERNEL_SIZE))-1
		sprintf(LABEL_NAME "SEL_%d" x)
		DrawLabelCommon(MASKFILE,LABEL_NAME, cvChannel)
		sprintf(LABEL_NAME "WL_IA_%d" x)
		DrawLabelCommon(MASKFILE,LABEL_NAME, cvChannel)
)
DrawLabelCommon(MASKFILE,"AVG", cvChannel)
DrawLabelCommon(MASKFILE,"RST", cvChannel)
DrawLabelCommon(MASKFILE,"MULTIPLY", cvChannel)
DrawLabelCommon(MASKFILE,"PRECHG_IA", cvChannel)
DrawLabelCommon(MASKFILE,"PRECHG_W", cvChannel)

DrawLabelCommon(MASKFILE,"D_W", cvChannel)
DrawLabelCommon(MASKFILE,"WR_IA_ENABLE", cvChannel)

DrawLabelCommon(MASKFILE,"SEL_IA_W", cvChannel)
DrawLabelCommon(MASKFILE,"VSSA", cvChannel)
DrawLabelCommon(MASKFILE,"VDDA", cvChannel)


default = 8
i = default
j = 4
schCreatePin(cvChannel iopin "VSSA" "inputOutput" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel iopin "VDDA" "inputOutput" nil 7:i "R0") i = i + 0.25

schCreatePin(cvChannel ipin "SEL_0" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "SEL_1" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "SEL_2" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "MULTIPLY" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "RST" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "AVG" "input" nil 7:i "R0") i = i + 0.25

schCreatePin(cvChannel ipin "WL_IA_0" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "WL_IA_1" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "WL_IA_2" "input" nil 7:i "R0") i = i + 0.25

schCreatePin(cvChannel ipin "PRECHG_W" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "PRECHG_IA" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "WR_W_EN" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "WR_IA_ENABLE" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "SEL_IA_W" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvChannel ipin "D_W" "input" nil 7:i "R0") i = i + 0.25

i = default
j = 8

for(x 0 IMAGE_WIDTH-1
	i = i + 0.25	
	sprintf(D_IA_PIN "D_IA_%d" x)
	schCreatePin(cvChannel ipin D_IA_PIN "input" nil j+1:i "R0")

)

for(x 0 KERNEL_SIZE-1
	i = i + 0.25	
	sprintf(WL_PIN "WL%d" x)
	schCreatePin(cvChannel ipin WL_PIN "input" nil j:i "R0")

)



for(x 0 IMAGE_WIDTH-1
			i = i + 0.25
			sprintf(VAVG_PIN "VAVG_%d" x)
			schCreatePin(cvChannel opin VAVG_PIN "output" nil j+2:i "R0")
			if( i >= default+0.25*14 then i = default j = j + 1)
)



testPins = schSchemToPinList( LIBNAME CHANNELFILE "schematic")
schPinListToSymbol( LIBNAME CHANNELFILE "symbol" testPins )
schCheck(cvChannel)
dbSave(cvChannel)

load("BatchNorm_PIPELINED.il")
load("Layer_PIPELINED_procedure.il")

for(i 0 (length LAYERS)-1
INPUT = INPUT_DIMENSION
if(i != 0 then INPUT = nth(i-1, LAYERS))
layerPipeline(INPUT, nth(i, LAYERS))
)
load("NeuralNetwork_PIPELINED.il")
