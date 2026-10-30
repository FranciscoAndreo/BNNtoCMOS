;-------------------------------------------------------------------------------
; Channel.il -- FLASH channel (level 4): one mask per output pixel, CHANNELFILE.
;
; IMAGE_HEIGHT x IMAGE_WIDTH masks convolve one input channel of the image in a
; single cycle. Mask (r, c) drives VAVG_<r*IMAGE_WIDTH+c> and reads the 3x3
; window around (r, c): pin IA<3*dw+dh> gets input IA_<r+dh-1>_<c+dw-1>, or VSSA
; outside the image ("same" padding with -1). Then builds the batch-norm and
; layer cells (Layer_FLASH.il) and the network (NeuralNetwork_FLASH.il).
;-------------------------------------------------------------------------------
deleteSchematic(LIBNAME CHANNELFILE "schematic")
cvChannel = dbOpenCellViewByType( LIBNAME CHANNELFILE "schematic" "schematic" "a" )
MASK_SYMBOL = dbOpenCellViewByType( LIBNAME MASKFILE "symbol" "" "r" )

x = 1
y = 1
for( i 1 IMAGE_WIDTH*IMAGE_HEIGHT
	mascara = schCreateInst( cvChannel MASK_SYMBOL nil 3.5*x:y "R0" )
	DrawLabelID(mascara,"VAVG","VAVG_", i-1, cvChannel)
	row = quotient(i-1 IMAGE_WIDTH)
	col = remainder(i-1 IMAGE_WIDTH)
	for(dw 0 2
		for(dh 0 2
			r = row+dh-1
			c = col+dw-1
			if(r >= 0 && r < IMAGE_HEIGHT && c >= 0 && c < IMAGE_WIDTH
				then sprintf(s "IA_%d_%d" r c)
				else s = "VSSA")
			DrawLabelName(mascara, sprintf(nil "IA%d" 3*dw+dh), s, cvChannel)))
	x += 1
	if(x > IMAGE_WIDTH
		then y -=5
		x = 1
		)
	)

for(x 0 KERNEL_SIZE-1
		sprintf(LABEL_NAME "WL%d" x)
		DrawLabelCommon(MASKFILE,LABEL_NAME, cvChannel)
)

DrawLabelCommon(MASKFILE,"RST", cvChannel)
DrawLabelCommon(MASKFILE,"PRECHG_W", cvChannel)
DrawLabelCommon(MASKFILE,"D", cvChannel)
DrawLabelCommon(MASKFILE,"AVG", cvChannel)
DrawLabelCommon(MASKFILE,"MULTIPLY", cvChannel)

DrawLabelCommon(MASKFILE,"VDDA", cvChannel)
DrawLabelCommon(MASKFILE,"VSSA", cvChannel)

pinPairs = '(("VDDA" "inputOutput") ("VSSA" "inputOutput") ("PRECHG_W" "input") ("RST" "input") ("AVG" "input") ("MULTIPLY" "input") ("D" "input"))

default = 13
i = default
j = 4
foreach( pair pinPairs
i = i + 0.25
cond(((cadr(pair) == "input" ) (drawingpin = ipin))
        ((cadr(pair) == "output")(drawingpin = opin))
        ((cadr(pair) == "inputOutput")(drawingpin = iopin)))
schCreatePin(cvChannel drawingpin car(pair) cadr(pair) nil j:i "R0")
if( i >= default+0.25*14 then i = default j = j + 1)
)

for(x 0 KERNEL_SIZE-1
		i = i + 0.25
		sprintf(INPUT_PIN "WL%d" x)
		schCreatePin(cvChannel ipin INPUT_PIN "input" nil j:i "R0")
		if( i >= default+0.25*14 then i = default j = j + 1)
)

; Input pixels IA_<row>_<column>.
for(r 0 IMAGE_HEIGHT-1
	for(c 0 IMAGE_WIDTH-1
			i = i + 0.25
			sprintf(INPUT_PIN "IA_%d_%d" r c)
			schCreatePin(cvChannel ipin INPUT_PIN "input" nil j:i "R0")
			if( i >= default+0.25*14 then i = default j = j + 1)
	)
)

for(x 0 IMAGE_WIDTH*IMAGE_HEIGHT-1
			i = i + 0.25
			sprintf(OUTPUT_PIN "VAVG_%d" x)
			schCreatePin(cvChannel opin OUTPUT_PIN "output" nil j:i "R0")
			if( i >= default+0.25*14 then i = default j = j + 1)
)

testPins = schSchemToPinList( LIBNAME CHANNELFILE "schematic")
schPinListToSymbol( LIBNAME CHANNELFILE "symbol" testPins )
schCheck(cvChannel)
dbSave(cvChannel)
dbClose(cvChannel)
load("BatchNorm_FLASH.il")
load("Layer_FLASH.il")

for(i 0 (length LAYERS)-1
INPUT = INPUT_DIMENSION
if(i != 0 then INPUT = nth(i-1, LAYERS))
layerFlash(INPUT, nth(i, LAYERS))
)

load("NeuralNetwork_FLASH.il")
