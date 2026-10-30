;-------------------------------------------------------------------------------
; lay2schem_library.il -- placement and wiring helpers shared by the generators.
;
; Connections are made with net labels: each helper draws a short wire stub on
; an instance pin and labels it, so pins with the same label are connected.
; The helpers do nothing for a pin name that the instance does not have.
;-------------------------------------------------------------------------------

; Pin masters used for every schematic pin.
ipin = dbOpenCellViewByType("basic" "ipin" "symbol" nil "r")
opin = dbOpenCellViewByType("basic" "opin" "symbol" nil "r")
iopin = dbOpenCellViewByType("basic" "iopin" "symbol" nil "r")

; Length of the wire stubs drawn by the label helpers.
XSpacing = 0.4

procedure( deleteSchematic( libName cellName viewName )
;---------------------------------
; Delete cellName/viewName from libName so it can be generated again.
;---------------------------------
  let( (cellview)
    cellview = dbOpenCellViewByType( libName cellName viewName viewName "w" )
    if( cellview then
      dbDeleteObject( cellview )
      printf("Successfully deleted %s %s %s\n" libName cellName viewName)
      t
    else
      printf("Error: Could not open %s %s %s for deletion\n" libName cellName viewName)
      nil
    ) ;if
  ) ;let
) ;procedure

procedure( l2sEnsureLib( libName )
;---------------------------------
; Return the library libName, creating it in the working directory if it
; does not exist yet.
;---------------------------------
  unless( ddGetObj(libName)
    printf("Lay2Schem: creating library %s in %s\n" libName getWorkingDir())
    ddCreateLib(libName strcat(getWorkingDir() "/" libName)))
  ddGetObj(libName)
)

;---------------------------------
; Batch-norm model. With BATCHNORM_MODEL = "ahdlLib" the batch-norm cells get,
; for every output OA_<f>_<i>, two behavioural cells of Cadence's ahdlLib
; (Verilog-A, simulation only): a comparator of VAVG_<f>_<i> against B_<f>,
; and a D flip-flop that latches the decision when RST rises, at the start of
; the next compute cycle, so the next layer reads a stable bit. Filters with
; BN_INVERT compare B against VAVG instead. In PIPELINED layers (gated), an AND
; gate with the layer's EN input sits before the flip-flop: with EN low the
; layer outputs 0 (activation -1), which pads the rows above and below the
; image for the next layer.
;---------------------------------
procedure( l2sBatchNormModel()
  boundp('BATCHNORM_MODEL) && BATCHNORM_MODEL == "ahdlLib")

procedure( l2sLayerIndex(filters)
  ; Position of the layer with this many filters in LAYERS (filter counts are
  ; unique, as the cell names require).
  let( (rest) rest = member(filters LAYERS) when( rest length(LAYERS) - length(rest))))

procedure( l2sFillBatchNorm(cv filters outputs @optional gated)
  let( (l2sBnLayer l2sBnCmp l2sBnFF l2sBnAnd l2sBnX l2sBnY l2sBnInv l2sBnNet l2sBnC l2sBnD l2sBnA
        l2sBnVdd l2sBnLogic)
    unless( ddGetObj("ahdlLib")
      error("Lay2Schem: BATCHNORM_MODEL \"ahdlLib\" needs the library ahdlLib in cds.lib: DEFINE ahdlLib $CDS_INST_DIR/tools/dfII/samples/artist/ahdlLib"))
    l2sBnLayer = l2sLayerIndex(filters)
    l2sBnCmp = dbOpenCellViewByType("ahdlLib" "comparator" "symbol" "" "r")
    l2sBnFF = dbOpenCellViewByType("ahdlLib" "d_ff" "symbol" "" "r")
    l2sBnAnd = gated && dbOpenCellViewByType("ahdlLib" "and_gate" "symbol" "" "r")
    l2sBnVdd = sprintf(nil "%g" TB_VDD)
    l2sBnLogic = list(list("vlogic_high" l2sBnVdd) list("vlogic_low" "0") list("vtrans" sprintf(nil "%g" TB_VDD/2))
                      list("tdel" "1n") list("trise" "1n") list("tfall" "1n"))
    l2sBnX = 3*filters + 8
    for( l2sBnF 0 filters-1
      l2sBnInv = boundp('BN_INVERT) && BN_INVERT && l2sBnLayer && nth(l2sBnF nth(l2sBnLayer BN_INVERT))
      for( l2sBnP 0 outputs-1
        l2sBnY = 2.0*(l2sBnF*outputs + l2sBnP)
        l2sBnNet = sprintf(nil "%d_%d" l2sBnF l2sBnP)
        l2sBnC = schCreateInst(cv l2sBnCmp nil list(l2sBnX l2sBnY) "R0")
        foreach( l2sBnProp list(list("sigout_high" l2sBnVdd) list("sigout_low" "0")
                                list("sigin_offset" "0") list("comp_slope" "1e4"))
          dbReplaceProp(l2sBnC car(l2sBnProp) "string" cadr(l2sBnProp)))
        DrawLabelName(l2sBnC if(l2sBnInv "sigref" "sigin") strcat("VAVG_" l2sBnNet) cv)
        DrawLabelName(l2sBnC if(l2sBnInv "sigin" "sigref") sprintf(nil "B_%d" l2sBnF) cv)
        DrawLabelName(l2sBnC "sigout" strcat("CMP_" l2sBnNet) cv)
        when( gated
          l2sBnA = schCreateInst(cv l2sBnAnd nil list(l2sBnX + 5 l2sBnY) "R0")
          foreach( l2sBnProp l2sBnLogic dbReplaceProp(l2sBnA car(l2sBnProp) "string" cadr(l2sBnProp)))
          DrawLabelName(l2sBnA "vin1" strcat("CMP_" l2sBnNet) cv)
          DrawLabelName(l2sBnA "vin2" "EN" cv)
          DrawLabelName(l2sBnA "vout" strcat("ENB_" l2sBnNet) cv))
        l2sBnD = schCreateInst(cv l2sBnFF nil list(l2sBnX + if(gated 10 5) l2sBnY) "R0")
        foreach( l2sBnProp cons(list("vtrans_clk" "0.3") l2sBnLogic)
          dbReplaceProp(l2sBnD car(l2sBnProp) "string" cadr(l2sBnProp)))
        DrawLabelName(l2sBnD "vin_d" strcat(if(gated "ENB_" "CMP_") l2sBnNet) cv)
        DrawLabelName(l2sBnD "vclk" "RST" cv)
        DrawLabelName(l2sBnD "vout_q" strcat("OA_" l2sBnNet) cv)
        DrawLabelName(l2sBnD "vout_qbar" strcat("NC_" l2sBnNet) cv)))
    t))

;---------------------------------
; Generation entry points. They read the settings of MAIN_PARAMETERS.il.
;---------------------------------
procedure( l2sGenerateFlash()
  LIBNAME = LIBNAME_FLASH
  MASKFILE = "SKILL_FLASH_MASK_8T"
  CHANNELFILE = "SKILL_FLASH_CHANNEL_8T"
  LAYERFILE = "SKILL_FLASH_LAYER_8T"
  BATCHFILE = "SKILL_FLASH_BATCHNORM_"
  NNFILE = "SKILL_FLASH_NEURALNETWORK"
  COMPONENT_WRITEDRIVER = COMPONENT_WRITEDRIVER_FLASH
  l2sEnsureLib(LIBNAME)
  load("Flash.il")
  when( boundp('TB_GENERATE) && TB_GENERATE
    load("Testbench.il")
    l2sGenerateTestbench())
  when( boundp('REPORT) && REPORT
    load("Report.il")
    l2sSummary())
)

procedure( l2sGeneratePipelined()
  LIBNAME = LIBNAME_PIPELINED
  MASKFILE = "SKILL_PIPELINED_MASK_8T"
  CHANNELFILE = "SKILL_PIPELINED_CHANNEL_8T"
  LAYERFILE = "SKILL_PIPELINED_LAYER_8T"
  BATCHFILE = "SKILL_PIPELINED_BATCHNORM_"
  NNFILE = "SKILL_PIPELINED_NEURALNETWORK"
  COMPONENT_WRITEDRIVER = COMPONENT_WRITEDRIVER_PIPELINED
  l2sEnsureLib(LIBNAME)
  load("Pipelined.il")
  when( boundp('TB_GENERATE) && TB_GENERATE
    load("Testbench.il")
    l2sGenerateTestbench())
  when( boundp('REPORT) && REPORT
    load("Report.il")
    l2sSummary())
)

procedure( l2sGenerate(config)
  unless( member(config '("FLASH" "PIPELINED" "BOTH"))
    error("Lay2Schem: CONFIG must be \"FLASH\", \"PIPELINED\" or \"BOTH\", not %L\n" config))
  when( config == "PIPELINED" || config == "BOTH" l2sGeneratePipelined())
  when( config == "FLASH" || config == "BOTH" l2sGenerateFlash())
  t
)

procedure( ListToWire(LISTA,NAME, cv, DIRECTION)
;---------------------------------
; Connect the points of LISTA with wires and label them NAME.
; DIRECTION ("R" or "L") is the side the wires leave the pins from.
;---------------------------------
Z = nil
X = nil
XSpacing = 0.4
ROffset = (XSpacing:0)
LOffset = (-XSpacing:0)
if(DIRECTION == "R" Offset = ROffset)
if(DIRECTION != "R" Offset = LOffset)
FLAG = nil
foreach( Punto LISTA
	{
		X = Punto
		if( FLAG != nil {
						wireId = schCreateWire( cv "route" "full" list(Z X) XSpacing 0.1 0)
						schCreateWireLabel(cv car(wireId) addPoints(addPoints(X Offset) (car(Offset)/2:0)) NAME "centerCenter" "R0" "fixed" 0.0625 nil)
						})
		Z = X
		if(FLAG != nil Z = addPoints(Z Offset))

		FLAG = 1
	})
)

procedure(addPoints(point1 point2)
;---------------------------------
; Sum of two points.
;---------------------------------
  let((result)
    result = list(
      car(point1) + car(point2) ; add x-coordinates
      cadr(point1) + cadr(point2) ; add y-coordinates
    )
	result
  )
)

procedure( DrawWireOfSamePin(CELLNAME,PINNAME, cv)
;---------------------------------
; Wire together pin PINNAME of every instance of master CELLNAME in cv.
; Example: BL and BLN of the bitcells of a mask.
;---------------------------------
A = nil
lista = nil
foreach( Instance cv~> instances
		when(Instance ~> cellName == CELLNAME
			foreach( Pin Instance~>instTerms
				when( Pin ~> name == PINNAME
					{
					A = Pin ~> term ~> pins
					A = dbTransformPoint(centerBox(car(A)~>fig~>bBox) Instance~>transform)
					if( car(centerBox(Instance ~> bBox)) < car(A)
					then DIRECTION = "R"
					else DIRECTION = "L")
					lista = cons(A lista)
					}))))

ListToWire(lista,PINNAME, cv, DIRECTION)
)

procedure( DrawLabel(CELLNAME,PINNAME, cv)
;---------------------------------
; Label pin PINNAME of every instance of master CELLNAME with PINNAME<n>,
; n = 0, 1, ... in instance order. Example: WL0..WL8 of the bitcells.
;---------------------------------
A = nil
lista = nil
INS_NUMBER = 0
foreach( Instance cv~> instances
		when(Instance ~> cellName == CELLNAME
			foreach( Pin Instance~>instTerms
				when( Pin ~> name == PINNAME
					{
					A = Pin ~> term ~> pins
					A = dbTransformPoint(centerBox(car(A)~>fig~>bBox) Instance~>transform)
					if( car(centerBox(Instance ~> bBox)) < car(A)
					then Offset = 0.2
					else Offset = -0.2)

					wireId = schCreateWire( cv "route" "full" list(A addPoints(A,(Offset:0))) XSpacing 0.1 0)
					schCreateWireLabel(cv car(wireId) addPoints(A,(Offset:0.05)) sprintf(nil "%s%d" PINNAME INS_NUMBER) "centerCenter" "R0" "euroStyle" 0.0625 nil)
					INS_NUMBER += 1
					}))))
)

procedure( DrawLabelCommon(CELLNAME,PINNAME, cv)
;---------------------------------
; Label pin PINNAME of every instance of master CELLNAME with PINNAME, which
; connects them all. Example: VDDA and VSSA.
;---------------------------------
A = nil
lista = nil
YOffset = 0
ORIENTATION = "R0"
INS_NUMBER = 0
foreach( Instance cv~> instances
		when(Instance ~> cellName == CELLNAME
			foreach( Pin Instance~>instTerms
				when( Pin ~> name == PINNAME
					{
					A = Pin ~> term ~> pins
					A = dbTransformPoint(centerBox(car(A)~>fig~>bBox) Instance~>transform)
					if( car(centerBox(Instance ~> bBox)) < car(A)
					then Offset = 0.2
					else Offset = -0.2)

					; Supply and bit lines leave the pin vertically.
					if(PINNAME == "VDDA" then Offset = 0 YOffset = 0.15 ORIENTATION = "R90")
					if(PINNAME == "VSSA" then Offset = 0 YOffset = 0.15 ORIENTATION = "R90")
					if(PINNAME == "BL" then Offset = 0 YOffset = 0.15 ORIENTATION = "R90")
					if(PINNAME == "BLN" then Offset = 0 YOffset = 0.15 ORIENTATION = "R90")

					wireId = schCreateWire( cv "route" "full" list(A addPoints(A,(Offset:YOffset))) XSpacing 0.1 0)
					schCreateWireLabel(cv car(wireId) addPoints(A,(Offset:YOffset+0.05)) sprintf(nil "%s" PINNAME) "centerCenter" ORIENTATION "euroStyle" 0.0625 nil)
					}))))
)

procedure( DrawLabelID(CELL_ID,PINNAME,LABEL, INS_NUMBER, cv)
;---------------------------------
; Label pin PINNAME of instance CELL_ID with LABEL<INS_NUMBER>.
;---------------------------------
DrawLabelName(CELL_ID PINNAME sprintf(nil "%s%d" LABEL INS_NUMBER) cv)
)

procedure( l2sChannelPitch(symbol dx dy)
;---------------------------------
; (dx dy) for placing instances of symbol on a grid: the given pitch, or the
; size of the symbol plus 0.5 if that is larger. The label stubs leave the pins
; by 0.2 at most (DrawLabelName), so those of neighbouring instances never touch.
;---------------------------------
  let( (box)
    box = symbol~>bBox
    list(max(dx caadr(box) - caar(box) + 0.5) max(dy cadadr(box) - cadar(box) + 0.5))))

procedure( DrawLabelName(CELL_ID,PINNAME,LABEL, cv)
;---------------------------------
; Label pin PINNAME of instance CELL_ID with LABEL. The stub leaves the pin
; outwards: vertically for a pin on the top or bottom edge of the instance,
; horizontally otherwise, so stubs of neighbouring pins never touch. (Pins sit
; on the edge of the bounding box, which may extend beyond side pins because of
; text.) Nothing happens if the instance has no such pin.
;---------------------------------
let( (term A box dx dy orient wireId)
	term = dbFindTermByName(CELL_ID~>master PINNAME)
	when( term
		A = dbTransformPoint(centerBox(car(term~>pins)~>fig~>bBox) CELL_ID~>transform)
		box = CELL_ID~>bBox
		if( min(cadadr(box)-cadr(A) cadr(A)-cadar(box)) <= 0.05 && min(car(A)-caar(box) caadr(box)-car(A)) > 0.05
		then
			dx = 0
			dy = if(cadadr(box)-cadr(A) <= cadr(A)-cadar(box) 0.15 -0.15)
			orient = "R90"
		else
			dx = if(car(centerBox(box)) < car(A) 0.2 -0.2)
			dy = 0
			orient = "R0")
		wireId = schCreateWire( cv "route" "full" list(A addPoints(A list(dx dy))) XSpacing 0.1 0)
		schCreateWireLabel(cv car(wireId) addPoints(A list(dx if(dy == 0 0.05 dy))) LABEL "centerCenter" orient "euroStyle" 0.0625 nil)
		t))
)

procedure( l2sCreatePins( cv pins x y perColumn )
;---------------------------------
; Create a schematic pin for each (name direction) in pins, direction being
; "input", "output" or "inputOutput". Pins are stacked downwards from x:y,
; perColumn per column, columns going to the left.
;---------------------------------
  let( (row master)
    row = 0
    foreach( pin pins
      master = cond( (cadr(pin) == "input" ipin) (cadr(pin) == "output" opin) (t iopin))
      schCreatePin(cv master car(pin) cadr(pin) nil list(x y - 0.25*row) "R0")
      row = row + 1
      when( row >= perColumn
        row = 0
        x = x - 1.5))
    t))

procedure( l2sPlacePinsLeft( cv pins )
;---------------------------------
; Create the pins (name direction) of cv in columns to the left of all its
; instances, where they cannot touch an instance pin or wire. Pins connect to
; the nets labelled with the same name.
;---------------------------------
  let( (boxes xmin ymax)
    boxes = mapcar(lambda((inst) inst~>bBox) cv~>instances)
    xmin = apply('min mapcar('caar boxes))
    ymax = apply('max mapcar('cadadr boxes))
    l2sCreatePins(cv pins xmin-2 ymax 400)))

procedure(findInstancesByName(cv name)
;---------------------------------
; Instances of master cell name in schematic cv.
;---------------------------------
  prog((instList)
    unless(cv
      printf("Error: Invalid cellview parameter.\n")
      return(nil)
    )
    unless(schIsSchEditOk(cv nil)
      printf("Error: Provided cellview is not an editable schematic.\n")
      return(nil)
    )
    instList = schGetMatchingObjects(cv "cellName" "==" name nil)
    when(null(instList)
      printf("No instances with name \"%s\" found.\n" name)
    )
    return(instList)
  )
)

procedure(abMultiDimArray(@rest dimensions)
;---------------------------------
; Multi-dimensional array, e.g. abMultiDimArray(3 4)[i][j].
;---------------------------------
    let((arr)
        if(integerp(car(dimensions)) && plusp(car(dimensions)) then
            arr=makeVector(car(dimensions))
            when(cdr(dimensions)
                for(ind 0 sub1(car(dimensions))
                    arr[ind]=apply('abMultiDimArray cdr(dimensions))
                )
            ) ; when
            arr
        else
            error("Dimension %L must be a positive integer\n" car(dimensions))
        ) ; if
    ) ; let
) ; procedure
