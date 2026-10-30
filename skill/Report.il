;-------------------------------------------------------------------------------
; Report.il -- estimate of a generated network. b2cSummary() walks the network
; cell NNFILE of LIBNAME down to the component cells and writes
; <working dir>/<LIBNAME>_report.txt with:
;   cells        instances of every cell in the whole network
;   area         component instances x the bounding box of their layout view:
;                active cell area, without routing
;   connections  instance terminals placed in each generated cell, once per
;                cell: the connections a designer would draw by hand
;   timing       latency and throughput at TB_PERIOD per compute cycle
;   energy       REPORT_ENERGY_PER_MASK_CYCLE x masks x cycles per inference
;-------------------------------------------------------------------------------

procedure( b2cSummaryWalk(lib cell)
  ; Table "lib/cell" -> instances of every cell below lib/cell (generated cells
  ; and components), counted through the hierarchy. Also records the instance
  ; terminals placed in each generated cell in B2C_SUMMARY_TERMS.
  let( (key memo cv counts sub below terms)
    key = strcat(lib "/" cell)
    memo = B2C_SUMMARY_MEMO[key]
    if( memo then memo else
      counts = makeTable(key 0)
      terms = 0
      cv = dbOpenCellViewByType(lib cell "schematic" "" "r")
      foreach( inst cv~>instances
        unless( inst~>libName == "basic"  ; pins
          terms = terms + length(inst~>instTerms)
          sub = strcat(inst~>libName "/" inst~>cellName)
          counts[sub] = counts[sub] + 1
          when( inst~>libName == lib && ddGetObj(lib inst~>cellName "schematic")
            below = b2cSummaryWalk(lib inst~>cellName)
            foreach( k below counts[k] = counts[k] + below[k]))))
      dbClose(cv)
      B2C_SUMMARY_TERMS[key] = terms
      B2C_SUMMARY_MEMO[key] = counts
      counts)))

procedure( b2cSummaryArea(key)
  ; Area of the layout bounding box of component "lib/cell", um2; nil without a
  ; layout view.
  let( (parts cv box area)
    parts = parseString(key "/")
    cv = ddGetObj(car(parts) cadr(parts) "layout") &&
      dbOpenCellViewByType(car(parts) cadr(parts) "layout" "" "r")
    when( cv
      box = cv~>bBox
      area = (caadr(box) - caar(box))*(cadadr(box) - cadar(box))
      dbClose(cv)
      area)))

procedure( b2cSummaryEnergy(arch)
  ; Energy per mask and cycle for arch, J, or nil.
  let( (entry)
    entry = if(boundp('REPORT_ENERGY_PER_MASK_CYCLE) assoc(arch REPORT_ENERGY_PER_MASK_CYCLE) nil)
    when( entry cadr(entry))))

procedure( b2cSummary()
  let( (pipelined arch file port counts keys leaves area missing total masks cycles fc latency
        extra throughput energy perInference macs C terms totalTerms)
    pipelined = (NNFILE == "SKILL_PIPELINED_NEURALNETWORK")
    arch = if(pipelined "PIPELINED" "FLASH")
    B2C_SUMMARY_MEMO = makeTable("memo" nil)
    B2C_SUMMARY_TERMS = makeTable("terms" 0)
    counts = b2cSummaryWalk(LIBNAME NNFILE)
    keys = sort(counts~>? 'alphalessp)
    leaves = setof(k keys car(parseString(k "/")) != LIBNAME)
    masks = counts[strcat(LIBNAME "/" MASKFILE)]
    macs = 0
    C = INPUT_DIMENSION
    foreach( F LAYERS macs = macs + KERNEL_SIZE*C*F*IMAGE_WIDTH*IMAGE_HEIGHT C = F)
    fc = boundp('FC_LAYERS) && FC_LAYERS

    file = strcat(getWorkingDir() "/" LIBNAME "_report.txt")
    port = outfile(file "w")
    fprintf(port "BNNtoCMOS estimate for %s/%s\n" LIBNAME NNFILE)
    fprintf(port "Network: %dx%d image, %d input channels, LAYERS %L, %s\n\n"
      IMAGE_HEIGHT IMAGE_WIDTH INPUT_DIMENSION LAYERS arch)

    fprintf(port "Cells in the network (instances)\n")
    foreach( k keys fprintf(port "  %-44s %10d\n" k counts[k]))

    fprintf(port "\nArea: component instances x layout bounding box (active cell area, no routing)\n")
    total = 0.0
    foreach( k leaves
      area = b2cSummaryArea(k)
      cond(
        ( car(parseString(k "/")) == "ahdlLib"  ; BATCHNORM_MODEL: simulation models
          fprintf(port "  %-44s %10d x  (behavioural model, no area)\n" k counts[k]))
        ( area
          total = total + area*counts[k]
          fprintf(port "  %-44s %10d x %10.2f um2 = %10.4f mm2\n" k counts[k] area area*counts[k]*1e-6))
        ( t
          missing = cons(k missing)
          fprintf(port "  %-44s %10d x  (no layout view)\n" k counts[k]))))
    fprintf(port "  total %.4f mm2%s\n" total*1e-6
      if(missing sprintf(nil ", without %d cells that have no layout view" length(missing)) ""))

    fprintf(port "\nConnections placed by the generator (instance terminals in each cell, once per cell)\n")
    totalTerms = 0
    foreach( k cons(strcat(LIBNAME "/" NNFILE) setof(k keys car(parseString(k "/")) == LIBNAME))
      terms = B2C_SUMMARY_TERMS[k]
      totalTerms = totalTerms + terms
      fprintf(port "  %-44s %10d\n" k terms))
    fprintf(port "  total %d\n" totalTerms)

    ; Timing: FLASH computes a whole image per cycle, one layer per cycle;
    ; PIPELINED takes one image row per cycle, and each layer needs the rows of
    ; its window plus one cycle (3 + 1). A fully connected layer would add one
    ; cycle (FLASH) or IMAGE_HEIGHT cycles (PIPELINED).
    cycles = if(pipelined IMAGE_HEIGHT 1)
    latency = if(pipelined (3 + 1)*length(LAYERS) length(LAYERS))
    throughput = 1.0/(cycles*TB_PERIOD)
    fprintf(port "\nTiming, one compute cycle per TB_PERIOD = %g s (%g MHz)\n" TB_PERIOD 1e-6/TB_PERIOD)
    fprintf(port "  latency of the convolution layers  %d cycles = %g s\n" latency latency*TB_PERIOD)
    when( fc
      extra = if(pipelined IMAGE_HEIGHT 1)
      fprintf(port "  with the fully connected layer     %d cycles = %g s (FC hardware is not generated)\n"
        latency + extra (latency + extra)*TB_PERIOD))
    fprintf(port "  throughput                         1 image per %d cycle%s = %g images/s\n"
      cycles if(cycles == 1 "" "s") throughput)

    energy = b2cSummaryEnergy(arch)
    fprintf(port "\nEnergy\n")
    if( energy then
      perInference = energy*masks*cycles
      fprintf(port "  %g J per mask and cycle (REPORT_ENERGY_PER_MASK_CYCLE)\n" energy)
      fprintf(port "  per image        %g J = %d masks x %d cycle%s\n" perInference masks cycles
        if(cycles == 1 "" "s"))
      fprintf(port "  per operation    %g J, for %d operations (2 per bitcell and image)\n"
        perInference/(2.0*macs) 2*macs)
    else
      fprintf(port "  not estimated: set REPORT_ENERGY_PER_MASK_CYCLE\n"))
    close(port)
    printf("BNNtoCMOS: %s: %d masks, %.4f mm2 cell area, latency %d cycles, report in %s\n"
      LIBNAME masks total*1e-6 latency file)
    file))
