;-------------------------------------------------------------------------------
; TestbenchReport.il -- b2cTbHtml(file): an HTML page with the results of a
; generated testbench. Its OCEAN script loads this file after the checks and
; writes <testbench>.html next to its log:
;   - the input image of the testbench, one map per input channel;
;   - for every filter of the last layer, the output map the trained network
;     gives, the one the simulated circuit gives, and the bits that differ;
;     the agreement per filter and per output row;
;   - for every layer, VAVG/VDD of the sampled nodes against their matching
;     fraction m, coloured by the comparator decision;
;   - the summary of the checks: fits, energy and, with fully connected layers,
;     the class.
; It reads the data of the OCEAN script: B2C_TITLE, B2C_ARCH, B2C_SHAPE,
; B2C_IMAGE, B2C_SAMPLES, B2C_OUTPUTS, B2C_MEASURED, B2C_ENERGY, B2C_CLASS and
; B2C_VDD. The page has no external dependencies.
;-------------------------------------------------------------------------------

B2C_HTML_ON = "#1f2937"    ; pixel +1
B2C_HTML_OFF = "#e5e7eb"   ; pixel -1
B2C_HTML_NONE = "#ffffff"  ; output not read
B2C_HTML_BAD = "#dc2626"   ; differs from the network
B2C_HTML_OK = "#16a34a"

procedure( b2cTbHtmlGrid(port rows cols size colours default)
  ; SVG of a rows x cols map: colours[pixel] (pixel = row*cols + col), or default.
  let( (gap colour)
    gap = if(size >= 6 1 0)
    fprintf(port "<svg width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\">"
      cols*size rows*size cols*size rows*size)
    fprintf(port "<rect width=\"%d\" height=\"%d\" fill=\"#ffffff\"/>" cols*size rows*size)
    for( pixel 0 rows*cols - 1
      colour = colours[pixel]
      unless( colour colour = default)
      fprintf(port "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" fill=\"%s\"/>"
        mod(pixel cols)*size quotient(pixel cols)*size size - gap size - gap colour))
    fprintf(port "</svg>")))

procedure( b2cTbHtmlFit(points)
  ; (slope offset r) of the least-squares line through points ((m v ok) ...).
  let( (n sx sy sxx sxy syy slope)
    n = 0  sx = 0.0  sy = 0.0  sxx = 0.0  sxy = 0.0  syy = 0.0
    foreach( p points
      n = n + 1  sx = sx + car(p)  sy = sy + cadr(p)
      sxx = sxx + car(p)*car(p)  sxy = sxy + car(p)*cadr(p)  syy = syy + cadr(p)*cadr(p))
    when( n > 1 && n*sxx - sx*sx > 0 && n*syy - sy*sy > 0
      slope = (n*sxy - sx*sy)/(n*sxx - sx*sx)
      list(slope (sy - slope*sx)/n (n*sxy - sx*sy)/sqrt((n*sxx - sx*sx)*(n*syy - sy*sy))))))

procedure( b2cTbHtmlScatter(port points fit)
  ; SVG of VAVG/VDD against m for points ((m v ok) ...), with the fit line.
  let( (x0 y0 xs ys vmax px py)
    x0 = 46  y0 = 222  xs = 300.0  ys = 210.0  vmax = 0.8
    fprintf(port "<svg width=\"360\" height=\"260\" viewBox=\"0 0 360 260\" font-size=\"10\" font-family=\"sans-serif\">")
    fprintf(port "<rect x=\"%d\" y=\"%d\" width=\"%g\" height=\"%g\" fill=\"#f9fafb\" stroke=\"#d1d5db\"/>" x0 y0 - 210 xs ys)
    foreach( m '(0.0 0.25 0.5 0.75 1.0)
      px = x0 + m*xs
      fprintf(port "<line x1=\"%g\" y1=\"%d\" x2=\"%g\" y2=\"%d\" stroke=\"#e5e7eb\"/>" px y0 - 210 px y0)
      fprintf(port "<text x=\"%g\" y=\"%d\" text-anchor=\"middle\">%g</text>" px y0 + 14 m))
    foreach( v '(0.0 0.2 0.4 0.6 0.8)
      py = y0 - v/vmax*ys
      fprintf(port "<line x1=\"%d\" y1=\"%g\" x2=\"%g\" y2=\"%g\" stroke=\"#e5e7eb\"/>" x0 py x0 + xs py)
      fprintf(port "<text x=\"%d\" y=\"%g\" text-anchor=\"end\">%g</text>" x0 - 4 py + 3 v))
    fprintf(port "<text x=\"%g\" y=\"%d\" text-anchor=\"middle\">matching fraction m</text>" x0 + xs/2 y0 + 30)
    fprintf(port "<text x=\"12\" y=\"%g\" text-anchor=\"middle\" transform=\"rotate(-90 12 %g)\">VAVG / VDD</text>"
      y0 - ys/2 y0 - ys/2)
    when( fit
      fprintf(port "<line x1=\"%d\" y1=\"%g\" x2=\"%g\" y2=\"%g\" stroke=\"#2563eb\" stroke-width=\"1.5\"/>"
        x0 y0 - min(max(cadr(fit) 0.0) vmax)/vmax*ys x0 + xs
        y0 - min(max(car(fit) + cadr(fit) 0.0) vmax)/vmax*ys))
    ; nodes decided as in the network first, the others on top
    foreach( p append(setof(q points caddr(q)) setof(q points !caddr(q)))
      fprintf(port "<circle cx=\"%g\" cy=\"%g\" r=\"%s\" fill=\"%s\" fill-opacity=\"0.8\"/>"
        x0 + car(p)*xs y0 - min(max(cadr(p) 0.0) vmax)/vmax*ys
        if(caddr(p) "2.6" "3.4") if(caddr(p) B2C_HTML_OK B2C_HTML_BAD)))
    fprintf(port "</svg>")))

procedure( b2cTbHtmlBars(port values)
  ; SVG bar chart of values ((label percent) ...), 0 to 100 %.
  let( (n bw x0 y0 hs px h every)
    n = length(values)
    bw = max(5 min(28 quotient(560 max(n 1))))
    every = if(n > 16 quotient(n + 13 14) 1)
    x0 = 34  y0 = 132  hs = 110.0
    fprintf(port "<svg width=\"%d\" height=\"156\" viewBox=\"0 0 %d 156\" font-size=\"10\" font-family=\"sans-serif\">"
      x0 + n*bw + 10 x0 + n*bw + 10)
    foreach( p '(0 50 100)
      fprintf(port "<line x1=\"%d\" y1=\"%g\" x2=\"%d\" y2=\"%g\" stroke=\"#e5e7eb\"/><text x=\"%d\" y=\"%g\" text-anchor=\"end\">%d%%</text>"
        x0 y0 - p/100.0*hs x0 + n*bw y0 - p/100.0*hs x0 - 4 y0 - p/100.0*hs + 3 p))
    px = x0
    foreach( v values
      h = cadr(v)/100.0*hs
      fprintf(port "<rect x=\"%d\" y=\"%g\" width=\"%d\" height=\"%g\" fill=\"%s\"><title>%s: %.1f%%</title></rect>"
        px y0 - h max(bw - 1 1) h if(cadr(v) >= 99.95 B2C_HTML_OK "#f59e0b") car(v) cadr(v))
      when( zerop(mod(px - x0 bw*every))
        fprintf(port "<text x=\"%g\" y=\"%d\" text-anchor=\"middle\">%s</text>" px + bw/2.0 y0 + 13 car(v)))
      px = px + bw)
    fprintf(port "</svg>")))

procedure( b2cTbHtmlCard(port value label)
  fprintf(port "<div class=\"card\"><b>%s</b><span>%s</span></div>" value label))

procedure( b2cTbHtml(file)
  ; Write the HTML page of the testbench results to file.
  let( (port rows cols channels layers F size expected simulated colours cells
        n agree perAgree perN rowAgree rowN index f pixel bit points fit
        decisions layerPoints vavg pct)
    rows = car(B2C_SHAPE)  cols = cadr(B2C_SHAPE)
    channels = caddr(B2C_SHAPE)  layers = nth(3 B2C_SHAPE)
    F = car(last(layers))
    size = max(3 min(18 quotient(196 max(rows cols))))
    ; outputs: expected and simulated bit per flattened index (row*W + col)*F + f
    expected = makeTable("expected" nil)  simulated = makeTable("simulated" nil)
    perAgree = makeTable("perAgree" 0)  perN = makeTable("perN" 0)
    rowAgree = makeTable("rowAgree" 0)  rowN = makeTable("rowN" 0)
    n = 0  agree = 0
    foreach( s B2C_OUTPUTS
      index = nth(3 s)
      expected[index] = caddr(s)
      bit = B2C_MEASURED[index]
      when( bit
        simulated[index] = bit
        f = mod(index F)  pixel = quotient(index F)
        n = n + 1  perN[f] = perN[f] + 1  rowN[quotient(pixel cols)] = rowN[quotient(pixel cols)] + 1
        when( bit == caddr(s)
          agree = agree + 1  perAgree[f] = perAgree[f] + 1
          rowAgree[quotient(pixel cols)] = rowAgree[quotient(pixel cols)] + 1)))
    ; sampled VAVG nodes, per layer: (m VAVG/VDD decision-as-in-the-network)
    layerPoints = makeTable("layerPoints" nil)
    foreach( s B2C_SAMPLES
      vavg = value(VT(car(s)) cadr(s))/B2C_VDD
      layerPoints[nth(6 s)] = cons(
        list(caddr(s) vavg
          if(nth(5 s) vavg <= nth(4 s) vavg >= nth(4 s)) == if(nth(5 s) caddr(s) <= nth(3 s) caddr(s) >= nth(3 s)))
        layerPoints[nth(6 s)]))

    port = outfile(file "w")
    unless( port error("b2cTbHtml: cannot write %s\n" file))
    fprintf(port "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n")
    fprintf(port "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n")
    fprintf(port "<title>%s</title>\n<style>\n" B2C_TITLE)
    fprintf(port "body{font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;margin:24px;color:#111827;background:#ffffff;max-width:1480px}\n")
    fprintf(port "h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 8px}p{font-size:13px;color:#374151;max-width:760px}\n")
    fprintf(port ".sub{color:#6b7280;font-size:13px}.cards{display:flex;flex-wrap:wrap;gap:12px;margin-top:16px}\n")
    fprintf(port ".card{border:1px solid #e5e7eb;border-radius:8px;padding:10px 14px;min-width:150px}.card b{display:block;font-size:18px}.card span{color:#6b7280;font-size:12px}\n")
    fprintf(port ".maps{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-start}figure{margin:0}figcaption{font-size:12px;color:#374151;margin-top:4px}\n")
    fprintf(port "table{border-collapse:collapse}td,th{padding:4px 14px 6px 0;vertical-align:top;font-size:12px;text-align:left;font-weight:normal;color:#374151}\n")
    fprintf(port ".key{display:inline-block;width:11px;height:11px;margin:0 4px 0 14px;vertical-align:-1px;border:1px solid #d1d5db}\n")
    fprintf(port ".filters{display:flex;flex-wrap:wrap;gap:20px 40px}.trio{display:flex;gap:10px}.ftitle{font-size:13px;margin-bottom:6px}.ftitle b{font-size:15px}\n")
    fprintf(port "</style></head><body>\n")

    fprintf(port "<h1>%s</h1>\n<div class=\"sub\">%s, %d&times;%d image, %d input channel%s, layers %L, simulated in Spectre</div>\n"
      B2C_TITLE B2C_ARCH rows cols channels if(channels == 1 "" "s") layers)
    fprintf(port "<div class=\"cards\">")
    when( n > 0
      b2cTbHtmlCard(port sprintf(nil "%.1f%%" 100.0*agree/n)
        sprintf(nil "output bits as in the network (%d of %d)" agree n)))
    for( layer 0 length(layers) - 1
      points = layerPoints[layer]
      when( points
        decisions = length(setof(p points caddr(p)))
        fit = b2cTbHtmlFit(points)
        b2cTbHtmlCard(port sprintf(nil "%d of %d" decisions length(points))
          sprintf(nil "layer %d decisions as in the network%s" layer
            if(fit sprintf(nil "; VAVG/VDD = %.3f m + %.3f, r = %.3f" car(fit) cadr(fit) caddr(fit)) "")))))
    when( B2C_ENERGY
      b2cTbHtmlCard(port sprintf(nil "%.3g pJ" B2C_ENERGY*1e12) "energy per mask and cycle, from VDDA"))
    when( B2C_CLASS
      b2cTbHtmlCard(port sprintf(nil "%d / %d" car(B2C_CLASS) cadr(B2C_CLASS))
        "class: simulated circuit / network (fully connected layers in software)"))
    fprintf(port "</div>\n")

    ; input image
    fprintf(port "<h2>Input image</h2>\n<p>The bits the testbench applies to <code>IN_*</code>.")
    fprintf(port "<span class=\"key\" style=\"background:%s\"></span>+1<span class=\"key\" style=\"background:%s\"></span>&minus;1</p>\n"
      B2C_HTML_ON B2C_HTML_OFF)
    fprintf(port "<div class=\"maps\">")
    for( z 0 channels - 1
      colours = makeTable("colours" nil)
      for( r 0 rows - 1
        for( c 0 cols - 1
          colours[r*cols + c] = if(nth(c nth(r nth(z B2C_IMAGE))) == 1 B2C_HTML_ON B2C_HTML_OFF)))
      fprintf(port "<figure>")
      b2cTbHtmlGrid(port rows cols size colours B2C_HTML_OFF)
      fprintf(port "<figcaption>channel %d</figcaption></figure>" z))
    fprintf(port "</div>\n")

    ; outputs of the last layer
    fprintf(port "<h2>Outputs of the last layer</h2>\n")
    if( n == 0 then
      fprintf(port "<p>Not read: the outputs compute only with <code>BATCHNORM_MODEL = \"ahdlLib\"</code>.</p>\n")
    else
      fprintf(port "<p>For each filter: the output map of the trained network, the one the simulated circuit gives, and the bits that differ.")
      fprintf(port "<span class=\"key\" style=\"background:%s\"></span>+1<span class=\"key\" style=\"background:%s\"></span>&minus;1"
        B2C_HTML_ON B2C_HTML_OFF)
      fprintf(port "<span class=\"key\" style=\"background:%s\"></span>differs<span class=\"key\" style=\"background:%s\"></span>not read</p>\n"
        B2C_HTML_BAD B2C_HTML_NONE)
      fprintf(port "<div class=\"filters\">\n")
      for( f 0 F - 1
        pct = if(perN[f] > 0 100.0*perAgree[f]/perN[f] 0.0)
        fprintf(port "<div><div class=\"ftitle\">filter %d &nbsp;<b>%.1f%%</b> &nbsp;(%d of %d)</div><div class=\"trio\">"
          f pct perAgree[f] perN[f])
        foreach( which '(expected simulated differences)
          colours = makeTable("colours" nil)
          for( p 0 rows*cols - 1
            index = p*F + f
            colours[p] = case( which
              ( expected
                cond( (expected[index] == nil B2C_HTML_NONE) (expected[index] == 1 B2C_HTML_ON) (t B2C_HTML_OFF)))
              ( simulated
                cond( (simulated[index] == nil B2C_HTML_NONE) (simulated[index] == 1 B2C_HTML_ON) (t B2C_HTML_OFF)))
              ( t
                cond( (simulated[index] == nil B2C_HTML_NONE)
                      (simulated[index] != expected[index] B2C_HTML_BAD) (t B2C_HTML_OFF)))))
          fprintf(port "<figure>")
          b2cTbHtmlGrid(port rows cols size colours B2C_HTML_NONE)
          fprintf(port "<figcaption>%s</figcaption></figure>"
            case( which (expected "network") (simulated "circuit") (t "differences"))))
        fprintf(port "</div></div>\n"))
      fprintf(port "</div>\n<h2>Agreement per output row</h2>\n<p>Output bits as in the network, all filters, by image row%s.</p>\n"
        if(B2C_ARCH == "PIPELINED" " (PIPELINED computes one row per cycle)" ""))
      let( (bars)
        for( r 0 rows - 1
          when( rowN[r] > 0
            bars = cons(list(sprintf(nil "%d" r) 100.0*rowAgree[r]/rowN[r]) bars)))
        b2cTbHtmlBars(port reverse(bars))))

    ; VAVG against m
    fprintf(port "<h2>VAVG of the sampled nodes</h2>\n<p>VAVG/VDD at the end of the cycle in which each node is valid, against the fraction m of matching bitcells that the weights and the layer input give; the line is the least-squares fit.")
    fprintf(port "<span class=\"key\" style=\"background:%s\"></span>comparator decision as in the network<span class=\"key\" style=\"background:%s\"></span>different</p>\n"
      B2C_HTML_OK B2C_HTML_BAD)
    fprintf(port "<div class=\"maps\">")
    for( layer 0 length(layers) - 1
      points = layerPoints[layer]
      when( points
        fprintf(port "<figure>")
        b2cTbHtmlScatter(port points b2cTbHtmlFit(points))
        fprintf(port "<figcaption>layer %d: %d nodes</figcaption></figure>" layer length(points))))
    fprintf(port "</div>\n<p class=\"sub\">Generated by BNNtoCMOS from the OCEAN script of this testbench.</p>\n</body></html>\n")
    close(port)
    t))
