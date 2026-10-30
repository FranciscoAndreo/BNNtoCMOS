;-------------------------------------------------------------------------------
; Flash.il -- FLASH mask (level 5): one 3x3 convolution, MASKFILE.
;
; Nine IMC bitcells on the mask's own bit lines BL/BLN (not pins: each mask is written
; by its own write driver), with a precharger. Bitcell
; k stores weight WL<k> and multiplies input IA<k>; all bitcells average their
; result on VAVG. Then builds the channel (Channel.il).
;-------------------------------------------------------------------------------
INS_NUMBER = 0

deleteSchematic(LIBNAME MASKFILE "schematic")

cvMain = dbOpenCellViewByType( LIBNAME MASKFILE "schematic" "" "a" )
cvSRAM = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_SRAM "symbol" "" "r" )
cvWRITEDRIVER = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_WRITEDRIVER "symbol" "" "r" )
cvPRECHARGER = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_PRECHARGER "symbol" "" "r" )

for( i 1 KERNEL_SIZE schCreateInst( cvMain cvSRAM nil 0:2*i "R0" ))
DrawWireOfSamePin(COMPONENT_SRAM,"BL", cvMain)
DrawWireOfSamePin(COMPONENT_SRAM,"BLN", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"VDDA", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"VSSA", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"AVG", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"VAVG", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"MULTIPLY", cvMain)
DrawLabelCommon(COMPONENT_SRAM,"RST", cvMain)

InstPRECHARGER = schCreateInst( cvMain cvPRECHARGER nil 0:(KERNEL_SIZE*2+2) "R0" )
InstWRITE = schCreateInst( cvMain cvWRITEDRIVER nil 0:0 "R0" )

DrawLabelCommon(COMPONENT_WRITEDRIVER,"BL", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"BLN", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"D", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"VDDA", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"VSSA", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"BL", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"BLN", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"VDDA", cvMain)

DrawLabelName(InstPRECHARGER, "PRECHG", "PRECHG_W", cvMain)

pinPairs = '(("VDDA" "inputOutput") ("VSSA" "inputOutput") ("PRECHG_W" "input")  ("RST" "input") ("AVG" "input") ("MULTIPLY" "input") ("D" "input") ("VAVG" "output"))

default = 13
i = default
j = 4
foreach( pair pinPairs
	i = i + 0.25
	cond(((cadr(pair) == "input" ) (drawingpin = ipin))
	        ((cadr(pair) == "output")(drawingpin = opin))
	        ((cadr(pair) == "inputOutput")(drawingpin = iopin)))
	schCreatePin(cvMain drawingpin car(pair) cadr(pair) nil j:i "R0")
	if( i >= default+0.25*14 then i = default j = j + 1)
)

for(x 0 KERNEL_SIZE-1
		i = i + 0.25
		sprintf(INPUT_PIN "WL%d" x)
		schCreatePin(cvMain ipin INPUT_PIN "input" nil j:i "R0")
		if( i >= default+0.25*14 then i = default j = j + 1)
)
for(x 0 KERNEL_SIZE-1
		i = i + 0.25
		sprintf(INPUT_PIN "IA%d" x)
		schCreatePin(cvMain ipin INPUT_PIN "input" nil j:i "R0")
		if( i >= default+0.25*14 then i = default j = j + 1)
)

; Bitcell k stores weight WL<k> and multiplies input IA<k>.
INS=0
SramList = findInstancesByName(cvMain COMPONENT_SRAM)
foreach(SRAM SramList
DrawLabelName(car(SRAM), "WL", sprintf(nil "WL%d" INS), cvMain)
DrawLabelName(car(SRAM), "AI", sprintf(nil "IA%d" INS), cvMain)
INS += 1
)
schCheck(cvMain)

testPins = schSchemToPinList( LIBNAME MASKFILE "schematic")
schPinListToSymbol( LIBNAME MASKFILE "symbol" testPins )
schCheck(cvMain)
dbSave(cvMain)
dbClose(cvMain)
load("Channel.il")
