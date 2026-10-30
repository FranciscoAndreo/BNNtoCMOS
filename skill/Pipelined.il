;-------------------------------------------------------------------------------
; Pipelined.il -- PIPELINED mask (level 5): one 3x3 convolution, MASKFILE.
;
; Nine IMC bitcells (weights WL<k>) plus a 6T dual column that buffers three
; image rows of this column (outputs C_0..C_2). Three switch matrices route
; this column (C_0..C_2), the left neighbour (C_3..C_5) and the right
; neighbour (C_6..C_8) to the bitcell inputs IA3..5, IA0..2 and IA6..8;
; SEL_0..2 rotate the buffered rows. Then builds the channel
; (Channel_PIPELINED.il).
;-------------------------------------------------------------------------------
INS_NUMBER = 0
deleteSchematic(LIBNAME MASKFILE "schematic")

cvMain = dbOpenCellViewByType( LIBNAME MASKFILE "schematic" "" "a" )
cvSRAM = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_SRAM "symbol" "" "r" )
cvSRAM_6T = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_SRAM_6T "symbol" "" "r" )

cvSWITCH = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_SWITCHMATRIX "symbol" "" "r" )
cvWRITEDRIVER = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_WRITEDRIVER "symbol" "" "r" )
cvPRECHARGER = dbOpenCellViewByType( COMPONENT_LIBNAME COMPONENT_PRECHARGER "symbol" "" "r" )
; Transistor that resets VAVG (RST).
cvNMOS = dbOpenCellViewByType( COMPONENT_NMOS_LIBNAME COMPONENT_NMOS "symbol" "" "r" )
NMOS = schCreateInst( cvMain cvNMOS nil 5:8 "MY" )


DrawLabelName(NMOS,"D","VAVG", cvMain)
DrawLabelName(NMOS,"B","VSSA", cvMain)
DrawLabelName(NMOS,"S","VSSA", cvMain)
DrawLabelName(NMOS,"G","RST", cvMain)


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
InstWRITE = schCreateInst( cvMain cvWRITEDRIVER nil 0:1 "R0" )

DrawLabelCommon(COMPONENT_WRITEDRIVER,"BL", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"BLN", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"D_W", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"D_IA", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"BLN_IA", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"VDDA", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"VSSA", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"WR_W_ENABLE", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"WR_IA_ENABLE", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"SEL_IA_W", cvMain)
DrawLabelCommon(COMPONENT_WRITEDRIVER,"BL_IA", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"BL", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"BLN", cvMain)
DrawLabelCommon(COMPONENT_PRECHARGER,"VDDA", cvMain)
DrawLabelName(InstPRECHARGER, "PRECHG", "PRECHG_W", cvMain)

; Bitcell k stores weight WL<k> and multiplies input IA<k>.
INS=0
SramList = findInstancesByName(cvMain COMPONENT_SRAM)
foreach(SRAM SramList
DrawLabelName(car(SRAM), "WL", sprintf(nil "WL%d" INS), cvMain)
DrawLabelName(car(SRAM), "AI", sprintf(nil "IA%d" INS), cvMain)
INS += 1
)


SWITCH_A = schCreateInst( cvMain cvSWITCH nil -4:10 "R0" )
DrawLabelName(SWITCH_A, "C_0", "C_3", cvMain)
DrawLabelName(SWITCH_A, "C_1", "C_4", cvMain)
DrawLabelName(SWITCH_A, "C_2", "C_5", cvMain)
DrawLabelName(SWITCH_A, "IA4", "IA1", cvMain)
DrawLabelName(SWITCH_A, "IA5", "IA2", cvMain)
DrawLabelName(SWITCH_A, "IA3", "IA0", cvMain)

SWITCH_B = schCreateInst( cvMain cvSWITCH nil -4:12 "R0" )
DrawLabelName(SWITCH_B, "C_0", "C_6", cvMain)
DrawLabelName(SWITCH_B, "C_1", "C_7", cvMain)
DrawLabelName(SWITCH_B, "C_2", "C_8", cvMain)
DrawLabelName(SWITCH_B, "IA4", "IA7", cvMain)
DrawLabelName(SWITCH_B, "IA5", "IA8", cvMain)
DrawLabelName(SWITCH_B, "IA3", "IA6", cvMain)

SWITCH_C = schCreateInst( cvMain cvSWITCH nil -4:14 "R0" )
DrawLabelName(SWITCH_C, "C_0", "C_0", cvMain)
DrawLabelName(SWITCH_C, "C_1", "C_1", cvMain)
DrawLabelName(SWITCH_C, "C_2", "C_2", cvMain)
DrawLabelName(SWITCH_C, "IA4", "IA4", cvMain)
DrawLabelName(SWITCH_C, "IA5", "IA5", cvMain)
DrawLabelName(SWITCH_C, "IA3", "IA3", cvMain)

DrawLabelCommon(COMPONENT_SWITCHMATRIX,"SEL_0", cvMain)
DrawLabelCommon(COMPONENT_SWITCHMATRIX,"SEL_1", cvMain)
DrawLabelCommon(COMPONENT_SWITCHMATRIX,"SEL_2", cvMain)
DrawLabelCommon(COMPONENT_SWITCHMATRIX,"VSSA", cvMain)

schCreateInst( cvMain cvSRAM_6T nil -7:16 "R0" )
DrawLabelCommon(COMPONENT_SRAM_6T,"WL_IA_0", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"WL_IA_1", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"WL_IA_2", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"VSSA", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"VDDA", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"C_0", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"C_1", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"C_2", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"PRECHG_IA", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"BL_IA", cvMain)
DrawLabelCommon(COMPONENT_SRAM_6T,"BLN_IA", cvMain)

i = 10
for(x 0 KERNEL_SIZE-1
		i = i + 0.25	
		sprintf(WL_PIN "WL%d" x)
		schCreatePin(cvMain ipin WL_PIN "input" nil 5:i "R0")
		sprintf(C_PIN "C_%d" x)
		if( x < 3 
		then 	schCreatePin(cvMain opin C_PIN "output" nil 6:i "R0") 
		else 	schCreatePin(cvMain ipin C_PIN "input" nil 6:i "R0"))
)
i = 10
schCreatePin(cvMain iopin "VSSA" "inputOutput" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain iopin "VDDA" "inputOutput" nil 7:i "R0") i = i + 0.25

schCreatePin(cvMain ipin "SEL_0" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "SEL_1" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "SEL_2" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "MULTIPLY" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "RST" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "AVG" "input" nil 7:i "R0") i = i + 0.25

schCreatePin(cvMain ipin "WR_W_ENABLE" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "WR_IA_ENABLE" "input" nil 7:i "R0") i = i + 0.25

schCreatePin(cvMain ipin "WL_IA_0" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "WL_IA_1" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "WL_IA_2" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "PRECHG_IA" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "PRECHG_W" "input" nil 7:i "R0") i = i + 0.25

schCreatePin(cvMain ipin "D_W" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "D_IA" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain ipin "SEL_IA_W" "input" nil 7:i "R0") i = i + 0.25
schCreatePin(cvMain opin "VAVG" "output" nil 7:i "R0") i = i + 0.25
testPins = schSchemToPinList( LIBNAME MASKFILE "schematic")
schPinListToSymbol( LIBNAME MASKFILE "symbol" testPins )
schCheck(cvMain)
dbSave(cvMain)
dbClose(cvMain)

load("Channel_PIPELINED.il")
