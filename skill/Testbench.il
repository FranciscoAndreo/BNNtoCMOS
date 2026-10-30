;-------------------------------------------------------------------------------
; Testbench.il -- testbench of a network cell: b2cGenerateTestbench() builds
; <NNFILE>_TB in LIBNAME with the network as instance DUT and one source per
; input pin. Every stimulus follows from the network (NETWORK_FILE, LAYERS,
; image size, CONFIG) and TB_IMAGE. It also writes an OCEAN script, which
; checks the simulation itself, and the PWL files of the stimulus.
;
; Timeline, in clock periods of TB_PERIOD seconds (S = 2 x KERNEL_SIZE):
;   periods 0..S-1  weight write, one kernel position k at a time, so that each
;                write driver writes one bitcell of its mask at once (it cannot
;                flip several). The data line (D, or D_W) is high in period 2k
;                and low in period 2k+1; word line WL<i>_<z>_<f>_<k> pulses in
;                the one of the two that matches its weight bit.
;                PIPELINED: WR_W_EN high, SEL_IA_W low.
;   period S+c   compute cycle c. Each cycle runs TB_CYCLE: reset, multiply,
;                average (RST, MULTIPLY, AVG).
;                FLASH: the image IN_* is applied from the start; layer i's
;                VAVG is valid at the end of cycle i, one cycle per layer. The
;                VAVG nodes of FLASH layers are not reset and keep part of the
;                previous cycle, so the testbench runs 2L+1 cycles and reads
;                the outputs at cycle 2L, when the network has settled.
;                PIPELINED: cycle c writes image row c-1 into row-buffer slot
;                c mod 3 (WL_IA_<c mod 3>), and SEL_<(c+1) mod 3> routes the
;                three buffered rows so that this newest row is the bottom row
;                of the window; both pulse at TB_ROW_WRITE, and the multiply of
;                the same cycle uses the new row. Cycle 0 and cycle H+1 write a
;                padding row (-1, like the VSSA padding of the columns); cycle 0
;                also writes it into slots 1 and 2 (b2cTbRowInit), so that no
;                slot starts from the DC operating point. Output row j of the
;                first layer is valid at the end of cycle j + B2C_TB_ROW_DELAY.
; Thresholds B_<i>_<f> are DC sources at (gain x m + offset) x TB_VDD, with the
; gain and offset of the architecture in TB_VAVG_TRANSFER: the VAVG level of
; matching fraction m, halfway between the two levels k/n around BN_THRESHOLD
; (n bitcells per filter), for the largest margin.
; PRECHG_* stay high. With BATCHNORM_MODEL, EN_<i> (PIPELINED) is high while
; layer i outputs image rows (latched in cycles 3+2i to H+2+2i), so that it
; outputs -1 (padding) before and after the image. TB_CONTROL overrides the
; source of any control pin. Outputs get no source.
;-------------------------------------------------------------------------------

B2C_TB_START = 18     ; write periods, 2 x KERNEL_SIZE (set by b2cGenerateTestbench)
B2C_TB_ROW_DELAY = 2  ; cycles from the write of row j-1 (cycle j) to output row j
B2C_TB_SAMPLE = 0.95  ; when to read VAVG, as a fraction of the cycle (after AVG)
; Most VAVG nodes and outputs the OCEAN script checks; set them before
; generating to check more.
unless( boundp('B2C_TB_MAX_SAMPLES) B2C_TB_MAX_SAMPLES = 200)
unless( boundp('B2C_TB_MAX_OUTPUTS) B2C_TB_MAX_OUTPUTS = 10000)

procedure( b2cTbSource(cv master net props @optional name)
  ; Place a source from net to gnd! with properties props ((name value) ...).
  let( (inst x y)
    x = B2C_TB_X - 2.5*quotient(B2C_TB_COUNT 40)
    y = 1.5*mod(B2C_TB_COUNT 40)
    B2C_TB_COUNT = B2C_TB_COUNT + 1
    inst = schCreateInst(cv master name list(x y) "R0")
    foreach( p props dbReplaceProp(inst car(p) "string" cadr(p)))
    DrawLabelName(inst "PLUS" net cv)
    DrawLabelName(inst "MINUS" "gnd!" cv)
    inst))

procedure( b2cTbVolts(level)
  sprintf(nil "%g" level*TB_VDD))

procedure( b2cTbSeconds(periods)
  sprintf(nil "%g" periods*TB_PERIOD))

procedure( b2cTbPulse(cv net low high delay width period)
  ; Levels as fractions of TB_VDD, times in clock periods.
  b2cTbSource(cv B2C_VPULSE net list(
    list("v1" b2cTbVolts(low)) list("v2" b2cTbVolts(high))
    list("td" b2cTbSeconds(delay)) list("pw" b2cTbSeconds(width)) list("per" b2cTbSeconds(period))
    list("tr" b2cTbSeconds(0.01)) list("tf" b2cTbSeconds(0.01)))))

procedure( b2cTbDC(cv net level @optional name)
  b2cTbSource(cv B2C_VDC net list(list("vdc" b2cTbVolts(level))) name))

procedure( b2cTbBit(name indices table)
  ; Element of the nested list table at indices, or 0 when table is unset.
  let( (value)
    value = table
    foreach( index indices value = if(listp(value) nth(index value) nil))
    if( numberp(value) value 0)))

procedure( b2cTbPWL(cv net file levels)
  ; Stepwise source: level n (fraction of TB_VDD) during period B2C_TB_START+n.
  let( (port t0)
    port = outfile(file "w")
    fprintf(port "0 %s\n" b2cTbVolts(car(levels)))
    for( n 0 length(levels)-1
      t0 = (B2C_TB_START + n)*TB_PERIOD
      fprintf(port "%g %s\n" t0 b2cTbVolts(if(n == 0 car(levels) nth(n-1 levels))))
      fprintf(port "%g %s\n" t0 + 0.01*TB_PERIOD b2cTbVolts(nth(n levels))))
    close(port)
    b2cTbSource(cv B2C_VPWLF net list(list("fileName" file)))))

procedure( b2cTbWave(cv net file windows @optional high)
  ; Source at high (default TB_VDD) inside each (start end) of windows (in clock
  ; periods, sorted, not overlapping) and 0 elsewhere.
  let( (port edge)
    unless( high high = TB_VDD)
    edge = 0.01*TB_PERIOD
    port = outfile(file "w")
    fprintf(port "0 %g\n" if(windows && caar(windows) <= 0 high 0.0))
    foreach( w windows
      when( car(w) > 0
        fprintf(port "%g 0\n%g %g\n" car(w)*TB_PERIOD car(w)*TB_PERIOD + edge high))
      fprintf(port "%g %g\n%g 0\n" cadr(w)*TB_PERIOD high cadr(w)*TB_PERIOD + edge))
    close(port)
    b2cTbSource(cv B2C_VPWLF net list(list("fileName" file)))))

procedure( b2cTbCycles(window cycles)
  ; window (from to), fractions of a cycle, in each compute cycle of cycles.
  mapcar(lambda((c) list(B2C_TB_START + c + car(window) B2C_TB_START + c + cadr(window))) cycles))

procedure( b2cTbRange(from to)
  let( (out) for( i from to out = cons(i out)) reverse(out)))

procedure( b2cTbMatch(layer f row col input channels)
  ; Fraction of matching bitcells of filter f of layer at pixel (row, col), for
  ; the input bits input[z][row][col] (channels of them), with the -1 padding
  ; of the circuit.
  let( (match r c a w)
    match = 0
    for( z 0 channels-1
      for( k 0 KERNEL_SIZE-1
        r = row + mod(k 3) - 1
        c = col + quotient(k 3) - 1
        a = if(r >= 0 && r < IMAGE_HEIGHT && c >= 0 && c < IMAGE_WIDTH b2cTbBit(nil list(z r c) input) 0)
        w = b2cTbBit(nil list(layer z f k) if(boundp('WEIGHTS) WEIGHTS nil))
        when( a == w match = match + 1)))
    match/(1.0*KERNEL_SIZE*channels)))

procedure( b2cTbExpected(f row col)
  ; Matching fraction of filter f of the first layer for TB_IMAGE.
  b2cTbMatch(0 f row col TB_IMAGE INPUT_DIMENSION))

procedure( b2cTbForward()
  ; Output bits [f][row][col] of the last layer for TB_IMAGE.
  car(last(b2cTbForwardAll())))

procedure( b2cTbForwardAll()
  ; Output bits [f][row][col] of every layer for TB_IMAGE, as the trained
  ; network computes them: each layer's matching fraction against its
  ; threshold (BN_THRESHOLD, BN_INVERT).
  let( (input channels out rows cols theta m maps)
    input = TB_IMAGE
    channels = INPUT_DIMENSION
    for( layer 0 length(LAYERS)-1
      out = nil
      for( f 0 nth(layer LAYERS)-1
        theta = b2cTbThreshold(layer f)
        rows = nil
        for( row 0 IMAGE_HEIGHT-1
          cols = nil
          for( col 0 IMAGE_WIDTH-1
            m = b2cTbMatch(layer f row col input channels)
            cols = cons(if(if(cadr(theta) m <= car(theta) m >= car(theta)) 1 0) cols))
          rows = cons(reverse(cols) rows))
        out = cons(reverse(rows) out))
      input = reverse(out)
      maps = cons(input maps)
      channels = nth(layer LAYERS))
    reverse(maps)))

procedure( b2cTbOutputs(pipelined)
  ; (net time bit index) for the network outputs OUT_*, at most
  ; B2C_TB_MAX_OUTPUTS: the bit the trained network gives, read when the circuit
  ; holds it, and its index in the flattened output (row*W + col)*F + f, the
  ; order of FC_WEIGHTS. FLASH: all outputs during cycle 2L. PIPELINED: output
  ; row j during cycle j + 2L + 1.
  let( (bits L F out count)
    bits = b2cTbForward()
    L = length(LAYERS)
    F = car(last(LAYERS))
    count = 0
    for( f 0 F-1
      for( row 0 IMAGE_HEIGHT-1
        for( col 0 IMAGE_WIDTH-1
          when( count < B2C_TB_MAX_OUTPUTS
            count = count + 1
            out = cons(
              if( pipelined
                list(sprintf(nil "/OUT_%d_%d" f col) (B2C_TB_START + row + 2*L + 1.5)*TB_PERIOD
                  nth(col nth(row nth(f bits))) (row*IMAGE_WIDTH + col)*F + f)
                list(sprintf(nil "/OUT_%d_%d" f row*IMAGE_WIDTH + col) (B2C_TB_START + 2*L + 0.5)*TB_PERIOD
                  nth(col nth(row nth(f bits))) (row*IMAGE_WIDTH + col)*F + f))
              out)))))
    reverse(out)))

procedure( b2cTbThreshold(i f)
  ; (theta invert) of filter f of layer i.
  list(if(boundp('BN_THRESHOLD) && BN_THRESHOLD nth(f nth(i BN_THRESHOLD)) 0.5)
       if(boundp('BN_INVERT) && BN_INVERT nth(f nth(i BN_INVERT)) nil)))

procedure( b2cTbChannels(layer)
  ; Input channels of layer.
  if(layer == 0 INPUT_DIMENSION nth(layer - 1 LAYERS)))

procedure( b2cTbLevel(theta invert n)
  ; B/VDD for threshold theta of a filter with n bitcells: the VAVG level
  ; halfway between the two matching fractions k/n around theta, so that the
  ; comparator has half a level of margin on both sides; clamped to the
  ; supply. Outside [0, 1] theta means a constant output, kept as it is.
  let( (m)
    m = cond(
      ( theta < 0 || theta > 1 theta)
      ( invert (floor(theta*n) + 0.5)/n)    ; output 1 up to level floor(theta n)
      ( t (ceiling(theta*n) - 0.5)/n))      ; output 1 from level ceil(theta n)
    max(0.0 min(1.0 B2C_TB_GAIN*m + B2C_TB_OFFSET))))

procedure( b2cTbSamples(pipelined layers)
  ; (net time m theta B/VDD invert layer) for VAVG nodes of the first layers
  ; (all of them when the batch-norm cells compute), at most
  ; B2C_TB_MAX_SAMPLES per layer. m is the matching fraction for the inputs the
  ; trained network gives the layer. FLASH: read in cycle 2L-1, when the
  ; network has settled. PIPELINED: row j of layer i at the end of cycle
  ; j + 2 + 2i.
  let( (out maps input channels theta F count n time L)
    L = length(LAYERS)
    maps = if(layers > 1 b2cTbForwardAll() nil)
    input = TB_IMAGE
    channels = INPUT_DIMENSION
    for( layer 0 layers-1
      F = nth(layer LAYERS)
      n = KERNEL_SIZE*channels
      count = 0
      for( f 0 F-1
        theta = b2cTbThreshold(layer f)
        for( row 0 IMAGE_HEIGHT-1
          for( col 0 IMAGE_WIDTH-1
            when( count < B2C_TB_MAX_SAMPLES
              count = count + 1
              time = if( pipelined
                (B2C_TB_START + row + B2C_TB_ROW_DELAY + 2*layer + B2C_TB_SAMPLE)*TB_PERIOD
                (B2C_TB_START + 2*L - 1 + B2C_TB_SAMPLE)*TB_PERIOD)
              out = cons(list(
                  sprintf(nil "/DUT/LAYER%d/VAVG_%d_%d" layer f if(pipelined col row*IMAGE_WIDTH + col))
                  time b2cTbMatch(layer f row col input channels)
                  car(theta) b2cTbLevel(car(theta) cadr(theta) n) cadr(theta) layer)
                out)))))
      when( maps input = nth(layer maps))
      channels = F)
    reverse(out)))

procedure( b2cTbMasks(pipelined)
  ; Number of 3x3 masks in the network.
  let( (n C)
    n = 0
    C = INPUT_DIMENSION
    foreach( F LAYERS
      n = n + C*F*if(pipelined IMAGE_WIDTH IMAGE_WIDTH*IMAGE_HEIGHT)
      C = F)
    n))

procedure( b2cTbFC(port outputs)
  ; The fully connected layers of the parameter file, for the class check of the
  ; OCEAN script: written when every network output is sampled and the first
  ; layer takes them all; else B2C_FC_WEIGHTS = nil.
  let( (n)
    n = IMAGE_HEIGHT*IMAGE_WIDTH*car(last(LAYERS))
    if( boundp('FC_WEIGHTS) && FC_WEIGHTS && boundp('FC_SCALE) && boundp('FC_OFFSET)
        && outputs == n && length(car(car(FC_WEIGHTS))) == n then
      fprintf(port "B2C_FC_INPUTS = %d\n; FC_WEIGHTS[layer][unit]: input bits (1 = +1)\nL2S_FC_WEIGHTS = '(\n" n)
      foreach( layer FC_WEIGHTS
        fprintf(port " (\n")
        foreach( unit layer fprintf(port "  %L\n" unit))
        fprintf(port " )\n"))
      fprintf(port ")\nL2S_FC_SCALE = '%L\nL2S_FC_OFFSET = '%L\n" FC_SCALE FC_OFFSET)
    else
      fprintf(port "B2C_FC_INPUTS = 0\nL2S_FC_WEIGHTS = nil\n"))))

procedure( b2cTbReportData(port pwlDir tbName)
  ; Data of the HTML page of the results (TestbenchReport.il): names, shape and
  ; the input image [z][row][col].
  fprintf(port "B2C_TITLE = %L\nL2S_ARCH = %L\nL2S_SHAPE = '(%d %d %d %L)\n"
    strcat(LIBNAME "/" tbName) if(NNFILE == "SKILL_PIPELINED_NEURALNETWORK" "PIPELINED" "FLASH")
    IMAGE_HEIGHT IMAGE_WIDTH INPUT_DIMENSION LAYERS)
  fprintf(port "B2C_REPORT_CODE = %L\nL2S_REPORT_FILE = %L\nL2S_IMAGE = '(\n"
    strcat(BNNTOCMOS_DIR "/TestbenchReport.il") strcat(pwlDir "/" tbName ".html"))
  for( b2cZ 0 INPUT_DIMENSION-1
    fprintf(port " (\n")
    for( b2cR 0 IMAGE_HEIGHT-1
      fprintf(port "  (")
      for( b2cC 0 IMAGE_WIDTH-1 fprintf(port " %d" b2cTbBit(nil list(b2cZ b2cR b2cC) TB_IMAGE)))
      fprintf(port ")\n"))
    fprintf(port " )\n"))
  fprintf(port ")\n"))

procedure( b2cTbOcean(pwlDir tbName cycles masks samples outputs)
  ; OCEAN script that runs the testbench and checks it: the first layer's VAVG
  ; against the expected matching fraction, the network outputs (when the
  ; batch-norm cells compute), and the supply energy.
  let( (port stop nets)
    stop = B2C_TB_START + cycles
    foreach( s append(samples outputs) unless( member(car(s) nets) nets = cons(car(s) nets)))
    port = outfile(strcat(pwlDir "/" tbName ".ocn") "w")
    fprintf(port "; OCEAN script for %s/%s, generated by BNNtoCMOS.\n" LIBNAME tbName)
    fprintf(port "; Add the model files of your technology, then: ocean -nograph < %s.ocn\n" tbName)
    fprintf(port "envSetVal(\"asimenv.startup\" \"projectDir\" 'string %L)\n" strcat(pwlDir "/simulation"))
    fprintf(port "simulator('spectre)\ndesign(%L %L \"schematic\")\n" LIBNAME tbName)
    if( boundp('TB_MODEL_FILES) && TB_MODEL_FILES then
      fprintf(port "modelFile(\n")
      foreach( m TB_MODEL_FILES fprintf(port "  '(%L %L)\n" car(m) cadr(m)))
      fprintf(port ")\n")
    else
      fprintf(port ";modelFile('(\"/path/to/models.scs\" \"tt\"))  ; or set TB_MODEL_FILES\n"))
    fprintf(port "resultsDir(%L)\n" strcat(pwlDir "/results"))
    fprintf(port "analysis('tran ?stop %L%s)\n" b2cTbSeconds(stop)
      if(boundp('TB_ERRPRESET) && TB_ERRPRESET sprintf(nil " ?errpreset %L" TB_ERRPRESET) ""))
    fprintf(port "saveOption('save %L)\n" if(boundp('TB_SAVE) && TB_SAVE TB_SAVE "selected"))
    fprintf(port "save('i \"/VVDDA/PLUS\")\n")
    foreach( n reverse(nets) fprintf(port "save('v %L)\n" n))
    ; A full netlist: the incremental netlister can miss a regenerated testbench
    ; and simulate the previous one.
    fprintf(port "temp(27)\ncreateNetlist(?recreateAll t ?display nil)\nrun()\nselectResult('tran)\n\n")
    fprintf(port "; (VAVG net, time, expected matching fraction m, threshold theta, B/VDD, invert, layer)\n")
    fprintf(port "B2C_SAMPLES = '(\n")
    foreach( s samples
      fprintf(port "  (%L %g %.6f %.6f %.6f %s %d)\n" nth(0 s) nth(1 s) nth(2 s) nth(3 s) nth(4 s)
        if(nth(5 s) "t" "nil") nth(6 s)))
    fprintf(port ")\n; (OUT net, time, bit of the trained network, index in the flattened output)\nL2S_OUTPUTS = '(\n")
    foreach( o outputs fprintf(port "  (%L %g %d %d)\n" nth(0 o) nth(1 o) nth(2 o) nth(3 o)))
    fprintf(port ")\nL2S_VDD = %g\nL2S_T0 = %g\nL2S_T1 = %g\nL2S_CYCLES = %d\nL2S_MASKS = %d\nL2S_LAYERS = %d\n"
      TB_VDD B2C_TB_START*TB_PERIOD stop*TB_PERIOD cycles masks 1 + apply('max mapcar(lambda((s) nth(6 s)) samples)))
    b2cTbFC(port length(outputs))
    b2cTbReportData(port pwlDir tbName)
    foreach( line list(
        "B2C_RESULTS = VT(car(car(B2C_SAMPLES)))"
        "B2C_MEASURED = makeTable(\"B2C_MEASURED\" nil)  B2C_ENERGY = nil  B2C_CLASS = nil"
        "unless( B2C_RESULTS"
        "  printf(\"B2C-TB-CHECK no simulation results: netlisting or simulation failed, see the messages above\\n\"))"
        ""
        "; VAVG/VDD against m for each layer: linear fit and correlation. Comparator"
        "; decisions on VAVG against B (VAVG >= B, or <= B for an inverted filter)"
        "; against those of the trained network (m >= theta, or <= theta)."
        "procedure( b2cCheckLayer(layer)"
        "  let( (n sx sy sxx sxy syy v slope r agree)"
        "    n = 0  sx = 0.0  sy = 0.0  sxx = 0.0  sxy = 0.0  syy = 0.0  agree = 0"
        "    foreach( s setof(x B2C_SAMPLES nth(6 x) == layer)"
        "      v = value(VT(car(s)) cadr(s))/B2C_VDD"
        "      printf(\"B2C-VAVG %s t=%g m=%.4f VAVG/VDD=%.4f\\n\" car(s) cadr(s) caddr(s) v)"
        "      n = n + 1  sx = sx + caddr(s)  sy = sy + v"
        "      sxx = sxx + caddr(s)*caddr(s)  sxy = sxy + caddr(s)*v  syy = syy + v*v"
        "      when( if(nth(5 s) v <= nth(4 s) v >= nth(4 s)) == if(nth(5 s) caddr(s) <= nth(3 s) caddr(s) >= nth(3 s))"
        "        agree = agree + 1))"
        "    when( n > 1 && n*sxx - sx*sx > 0 && n*syy - sy*sy > 0"
        "      slope = (n*sxy - sx*sy)/(n*sxx - sx*sx)"
        "      r = (n*sxy - sx*sy)/sqrt((n*sxx - sx*sx)*(n*syy - sy*sy))"
        "      printf(\"B2C-TB-CHECK layer %d, %d VAVG nodes: VAVG/VDD = %.4f*m + %.4f, r = %.4f\\n\" layer n slope (sy - slope*sx)/n r))"
        "    printf(\"B2C-TB-CHECK layer %d, comparator decisions (VAVG against B): %d of %d as in the network\\n\" layer agree n)))"
        "when( B2C_RESULTS"
        "  for( layer 0 B2C_LAYERS-1 b2cCheckLayer(layer)))"
        ""
        "when( B2C_RESULTS let( (e)"
        "  e = -B2C_VDD*integ(IT(\"/VVDDA/PLUS\") B2C_T0 B2C_T1)"
        "  printf(\"B2C-TB-ENERGY %g J from VDDA in %d compute cycles: %g J per mask and cycle (%d masks)\\n\""
        "    e B2C_CYCLES e/(B2C_CYCLES*B2C_MASKS) B2C_MASKS)"
        "  B2C_ENERGY = e/(B2C_CYCLES*B2C_MASKS)))"
        ""
        "; Network outputs against the trained network (needs BATCHNORM_MODEL)."
        "; With the fully connected layers of the parameter file, which are not"
        "; built in hardware, also the class from the simulated outputs."
        "procedure( b2cClass(bits)"
        "  let( (x y s best)"
        "    x = bits"
        "    for( i 0 length(B2C_FC_WEIGHTS)-1"
        "      y = nil"
        "      foreach( (w scale offset) nth(i B2C_FC_WEIGHTS) nth(i B2C_FC_SCALE) nth(i B2C_FC_OFFSET)"
        "        s = 0.0"
        "        foreach( (b v) w x  s = if(b == 1 s + v s - v))"
        "        y = cons(scale*s + offset y))"
        "      y = reverse(y)"
        "      when( i < length(B2C_FC_WEIGHTS)-1  x = mapcar(lambda((v) if(v >= 0 1.0 -1.0)) y)))"
        "    best = 0"
        "    for( u 1 length(y)-1  when( nth(u y) > nth(best y) best = u))"
        "    best))"
        "when( B2C_RESULTS let( (n agree bit measured expected)"
        "  n = 0  agree = 0"
        "  measured = makeTable(\"measured\" -1.0)  expected = makeTable(\"expected\" -1.0)"
        "  foreach( s B2C_OUTPUTS"
        "    n = n + 1"
        "    bit = if(value(VT(car(s)) cadr(s)) > B2C_VDD/2 1 0)"
        "    when( bit == caddr(s) agree = agree + 1)"
        "    B2C_MEASURED[nth(3 s)] = bit"
        "    measured[nth(3 s)] = if(bit == 1 1.0 -1.0)"
        "    expected[nth(3 s)] = if(caddr(s) == 1 1.0 -1.0))"
        "  when( n > 0"
        "    printf(\"B2C-TB-OUTPUT %d of %d output bits as in the network\\n\" agree n))"
        "  when( B2C_FC_WEIGHTS && n == B2C_FC_INPUTS let( (m e)"
        "    for( i 0 n-1  m = cons(measured[n-1-i] m)  e = cons(expected[n-1-i] e))"
        "    B2C_CLASS = list(b2cClass(m) b2cClass(e))"
        "    printf(\"B2C-TB-CLASS %d from the simulated outputs, %d from the network (fully connected layers in software)\\n\""
        "      car(B2C_CLASS) cadr(B2C_CLASS))))))"
        ""
        "; HTML page with the input image, the outputs and the sampled VAVG nodes."
        "when( B2C_RESULTS && isFile(B2C_REPORT_CODE)"
        "  load(B2C_REPORT_CODE)"
        "  when( errset(b2cTbHtml(B2C_REPORT_FILE) t)"
        "    printf(\"B2C-TB-REPORT %s\\n\" B2C_REPORT_FILE)))"
        ""
        "; Leave OCEAN when run as ocean -nograph < script; stay in a Virtuoso GUI."
        "unless( isCallable('hiGraphicMode) && hiGraphicMode() exit())"
        "")
      fprintf(port "%s\n" line))
    close(port)))

procedure( b2cTbRowInit(slot)
  ; PIPELINED: cycle 0 also writes its row (padding) into slots 1 and 2, in the
  ; reset and average thirds of the cycle (one cell per write driver at a time),
  ; so that no slot holds the state of the DC operating point when output row 0
  ; is computed: slot 2 gets its first image row in that same cycle 2.
  let( (window)
    window = cdr(assoc(nth(slot '(nil "RST" "AVG")) TB_CYCLE))
    when( window
      list(list(B2C_TB_START + car(window) + 0.02 B2C_TB_START + cadr(window))))))

procedure( b2cTbControl(cv name pipelined cycles pwlDir)
  ; Source of control pin name; nil if the pin is not a control input.
  let( (all window override slot file)
    all = b2cTbRange(0 cycles-1)
    file = strcat(pwlDir "/" name ".pwl")
    override = if(boundp('TB_CONTROL) assoc(name TB_CONTROL) nil)
    window = cdr(assoc(name TB_CYCLE))
    cond(
      ( override
        if( cadr(override) == "dc"
          b2cTbDC(cv name caddr(override))
          apply('b2cTbPulse cons(cv cons(name cddr(override))))))
      ( window b2cTbWave(cv name file b2cTbCycles(window all)))
      ( rexMatchp("^PRECHG_" name) b2cTbDC(cv name 1))
      ( name == "WR_W_EN" b2cTbWave(cv name file list(list(0 B2C_TB_START - 0.05))))
      ( member(name '("SEL_IA_W" "WR_IA_ENABLE"))
        b2cTbWave(cv name file list(list(B2C_TB_START - 0.02 B2C_TB_START + cycles))))
      ( pipelined && rexMatchp("^EN_[0-9]+$" name)
        ; layer i outputs the rows of the image, latched in cycles 3+2i to H+2+2i,
        ; and 0 (padding) before and after
        slot = atoi(substring(name 4))
        b2cTbWave(cv name file list(list(B2C_TB_START + 2.5 + 2*slot B2C_TB_START + IMAGE_HEIGHT + 2.5 + 2*slot))))
      ( pipelined && rexMatchp("^WL_IA_[0-2]$" name)  ; writes slot c mod 3 in cycle c
        slot = atoi(substring(name strlen(name)))
        b2cTbWave(cv name file append(b2cTbRowInit(slot)
          b2cTbCycles(TB_ROW_WRITE setof(c all mod(c 3) == slot)))))
      ( pipelined && rexMatchp("^SEL_[0-2]$" name)  ; newest row (slot c mod 3) at the bottom
        slot = atoi(substring(name strlen(name)))
        b2cTbWave(cv name file b2cTbCycles(TB_ROW_WRITE setof(c all mod(c + 1 3) == slot))
          TB_VDD*if(boundp('TB_SEL_HIGH) && TB_SEL_HIGH TB_SEL_HIGH 1.0)))
      ( t nil))))

procedure( b2cGenerateTestbench()
  let( (tbName cv nnSymbol dut dataPin pwlDir name parts value levels cycles box pipelined)
    pipelined = (NNFILE == "SKILL_PIPELINED_NEURALNETWORK")
    dataPin = if(pipelined "D_W" "D")
    cycles = if(pipelined IMAGE_HEIGHT + 2 + 4*length(LAYERS) 2*length(LAYERS) + 1)
    B2C_TB_START = 2*KERNEL_SIZE
    value = assoc(if(pipelined "PIPELINED" "FLASH") TB_VAVG_TRANSFER)
    B2C_TB_GAIN = if(value cadr(value) 1.0)
    B2C_TB_OFFSET = if(value caddr(value) 0.0)
    tbName = strcat(NNFILE "_TB")
    pwlDir = strcat(getWorkingDir() "/" LIBNAME "_" tbName)
    unless( isDir(pwlDir) createDir(pwlDir))
    B2C_VDC = dbOpenCellViewByType("analogLib" "vdc" "symbol" "" "r")
    B2C_VPULSE = dbOpenCellViewByType("analogLib" "vpulse" "symbol" "" "r")
    B2C_VPWLF = dbOpenCellViewByType("analogLib" "vpwlf" "symbol" "" "r")
    unless( boundp('WEIGHTS) && WEIGHTS
      printf("BNNtoCMOS: no WEIGHTS (NETWORK_FILE not set), the testbench writes 0 into every bitcell\n"))

    deleteSchematic(LIBNAME tbName "schematic")
    cv = dbOpenCellViewByType(LIBNAME tbName "schematic" "schematic" "w")
    nnSymbol = dbOpenCellViewByType(LIBNAME NNFILE "symbol" "" "r")
    dut = schCreateInst(cv nnSymbol "DUT" 0:0 "R0")
    box = dut~>bBox
    B2C_TB_X = caar(box) - 4
    B2C_TB_COUNT = 0

    foreach( term nnSymbol~>terminals
      name = term~>name
      DrawLabelName(dut name name cv)
      cond(
        ( term~>direction == "output" nil)
        ( name == "VDDA" b2cTbDC(cv name 1 "VVDDA"))
        ( name == "VSSA" b2cTbDC(cv name 0))
        ( name == dataPin  ; high in period 2k, low in period 2k+1
          b2cTbWave(cv name strcat(pwlDir "/" name ".pwl")
            mapcar(lambda((k) list(2*k 2*k + 1)) b2cTbRange(0 KERNEL_SIZE-1))))
        ( rexMatchp("^WL[0-9]+_[0-9]+_[0-9]+_[0-9]+$" name)
          ; WL<i>_<z>_<f>_<k>: pulse in period 2k for a 1, 2k+1 for a 0
          parts = mapcar('atoi parseString(substring(name 3) "_"))
          value = b2cTbBit(name parts if(boundp('WEIGHTS) WEIGHTS nil))
          b2cTbPulse(cv name 0 1 2*nth(3 parts) + if(value == 1 0.3 1.3) 0.4 1000))
        ( rexMatchp("^B_[0-9]+_[0-9]+$" name)
          parts = mapcar('atoi parseString(substring(name 3) "_"))
          value = b2cTbThreshold(car(parts) cadr(parts))
          b2cTbDC(cv name b2cTbLevel(car(value) cadr(value) KERNEL_SIZE*b2cTbChannels(car(parts)))))
        ( rexMatchp("^IN_" name)
          parts = mapcar('atoi parseString(substring(name 4) "_"))
          if( pipelined then
            ; IN_<z>_<col>: cycle c carries row c-1, padding (0) around the image
            levels = list(0)
            for( r 0 IMAGE_HEIGHT-1
              levels = cons(b2cTbBit(name list(car(parts) r cadr(parts)) TB_IMAGE) levels))
            b2cTbPWL(cv name strcat(pwlDir "/" name ".pwl") reverse(cons(0 levels)))
          else
            b2cTbDC(cv name b2cTbBit(name parts TB_IMAGE))))
        ( b2cTbControl(cv name pipelined cycles pwlDir))
        ( t
          printf("BNNtoCMOS: testbench pin %s has no source, tied to 0\n" name)
          b2cTbDC(cv name 0))))

    schCheck(cv)
    dbSave(cv)
    dbClose(cv)

    b2cTbOcean(pwlDir tbName cycles b2cTbMasks(pipelined)
      b2cTbSamples(pipelined if(b2cBatchNormModel() length(LAYERS) 1))
      if(b2cBatchNormModel() b2cTbOutputs(pipelined) nil))
    printf("BNNtoCMOS: testbench %s/%s with %d sources and %d compute cycles, OCEAN script in %s\n"
      LIBNAME tbName B2C_TB_COUNT cycles pwlDir)
    t))
