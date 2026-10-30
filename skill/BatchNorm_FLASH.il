;-------------------------------------------------------------------------------
; BatchNorm_FLASH.il -- batch-norm cell of a FLASH layer, <BATCHFILE>_<F>.
;
; Pins: inputs VAVG_<f>_<i> (averaged convolution of
; filter f, IMAGE_WIDTH*IMAGE_HEIGHT pixels) and thresholds B_<f>, outputs OA_<f>_<i>. Fill the
; schematic with the comparator of your design; parser/bnn_to_skill.py gives the
; threshold of each filter (BN_THRESHOLD). With BATCHNORM_MODEL = "ahdlLib" the
; cell gets behavioural comparators and latches instead, for simulation.
;-------------------------------------------------------------------------------
procedure( BatchFlash(DIMENSION_INPUT, FILTERS)

sprintf(Batch "%s_%d" BATCHFILE FILTERS)
deleteSchematic(LIBNAME Batch "schematic")
cvBatchNorm = dbOpenCellViewByType( LIBNAME Batch "schematic" "schematic" "a" )

j = 1
default = 2.5
i = default

schCreatePin(cvBatchNorm iopin "VSSA" "inputOutput" nil j:i "R0") i = i + 0.25
schCreatePin(cvBatchNorm iopin "VDDA" "inputOutput" nil j:i "R0") i = i + 0.25

j = j+1
i = default


	for(a 0 FILTERS-1
		for(b 0 IMAGE_WIDTH*IMAGE_HEIGHT-1
			sprintf(s "VAVG_%d_%d" a b)
			schCreatePin(cvBatchNorm ipin s "input" nil j:i "R0")
			sprintf(s "OA_%d_%d" a b)
			schCreatePin(cvBatchNorm opin s "output" nil j+1:i "R0") i = i + 0.25
		)

		i = default
		j = j + 3
	)


for(a 0 FILTERS-1
			sprintf(s "B_%d" a)
			schCreatePin(cvBatchNorm ipin s "input" nil j:i "R0") i = i + 0.25
		  
		i = default
		j = j + 3
	)


; BATCHNORM_MODEL "ahdlLib": behavioural comparator and latch per output
; (b2cFillBatchNorm, bnntocmos_library.il), clocked by RST.
when( b2cBatchNormModel()
	schCreatePin(cvBatchNorm ipin "RST" "input" nil j:i "R0")
	b2cFillBatchNorm(cvBatchNorm FILTERS IMAGE_WIDTH*IMAGE_HEIGHT))

testPins = schSchemToPinList( LIBNAME Batch "schematic")
schPinListToSymbol( LIBNAME Batch "symbol" testPins )


schCheck(cvBatchNorm)
dbSave(cvBatchNorm)
)

