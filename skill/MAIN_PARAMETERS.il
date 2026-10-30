;-------------------------------------------------------------------------------
; MAIN_PARAMETERS.il -- BNNtoCMOS entry point.
;
; Edit the settings below, then load this file from the CIW or the SKILL IDE:
;
;     BNNTOCMOS_DIR = "/path/to/BNNtoCMOS/skill"
;     load(strcat(BNNTOCMOS_DIR "/MAIN_PARAMETERS.il"))
;
; The generated cells appear in the output libraries (Library Manager).
;-------------------------------------------------------------------------------

unless( boundp('BNNTOCMOS_DIR) && stringp(BNNTOCMOS_DIR)
  error("BNNtoCMOS: set BNNTOCMOS_DIR to the directory of the .il files before loading MAIN_PARAMETERS.il\n"))
unless( member(BNNTOCMOS_DIR getSkillPath())
  setSkillPath(cons(BNNTOCMOS_DIR getSkillPath())))
load("bnntocmos_library.il") ; placement and wiring helpers

;------ NETWORK -----------------------------------------------------------------
; Either load the file written by parser/bnn_to_skill.py from a trained model...
NETWORK_FILE = nil ; e.g. "/path/to/NETWORK_PARAMETERS.il"
; ...or describe the network by hand (overwritten when NETWORK_FILE is set):
LAYERS = '(2 4)      ; number of filters of each convolution layer
IMAGE_WIDTH = 8
IMAGE_HEIGHT = 8
INPUT_DIMENSION = 1  ; channels of the input image
when( NETWORK_FILE load(NETWORK_FILE))
KERNEL_SIZE = 3*3    ; fixed: the masks are 3x3

;------ ARCHITECTURE ------------------------------------------------------------
; "FLASH": a whole image per clock cycle. "PIPELINED": one image row per cycle.
; "BOTH": generate both.
CONFIG = "PIPELINED"

;------ OUTPUT LIBRARIES (created in the working directory if missing) ----------
LIBNAME_FLASH = "BNNTOCMOS_FLASH"
LIBNAME_PIPELINED = "BNNTOCMOS_PIPELINED"

;------ COMPONENT LIBRARY ------------------------------------------------------
; Library holding the circuit cells below. docs/components.md lists the pins
; each cell must have.
COMPONENT_LIBNAME = "IMC_CELLS"
COMPONENT_SRAM = "SRAM_10T1C_V5"               ; IMC bitcell (both architectures)
COMPONENT_PRECHARGER = "PRECHARGER"            ; bit-line precharger (both)
COMPONENT_WRITEDRIVER_FLASH = "WRITE_DRIVER"   ; weight write driver (FLASH)
COMPONENT_WRITEDRIVER_PIPELINED = "WRITE_DRIVER_V5" ; weight/activation write driver (PIPELINED)
COMPONENT_SRAM_6T = "SRAM_6T_DUAL_COLUMN"      ; 3-row activation buffer (PIPELINED)
COMPONENT_SWITCHMATRIX = "SWITCH_MATRIX_3X3_A" ; row rotation of the buffer (PIPELINED)
; Transistor that resets VAVG in the PIPELINED mask: an NMOS from your
; technology library (terminals D G S B).
COMPONENT_NMOS_LIBNAME = "TECH_LIB"
COMPONENT_NMOS = "nmos"
; Batch-norm cells. nil: pin-only placeholders, to fill with your comparator.
; "ahdlLib": behavioural cells for simulation from Cadence's ahdlLib, which
; ships with Virtuoso (add it to cds.lib): per output, a comparator of VAVG against B_<f> and a flip-flop
; that latches the decision when RST rises; in PIPELINED layers also an AND gate
; with the layer's enable (network pins EN_<i>), which the testbench uses to pad
; the next layer. The whole network then simulates, and the testbench also
; checks every layer and the outputs OUT_*.
BATCHNORM_MODEL = nil
;-------------------------------------------------------------------------------

;------ TESTBENCH ---------------------------------------------------------------
; TB_GENERATE = t also builds <network>_TB: the network with a source on every
; input, an OCEAN script that checks the simulation, and PWL files (in
; <working dir>/<library>_<network>_TB). The stimulus follows from the network:
; weights and thresholds from NETWORK_FILE, the image from TB_IMAGE, and a
; schedule of compute cycles for the architecture and image size (one cycle per
; layer in FLASH; one image row per cycle in PIPELINED). See Testbench.il.
TB_GENERATE = nil
TB_VDD = 1.8        ; supply, V: the core supply of your technology
TB_PERIOD = 1e-6    ; clock period = one compute cycle, s
TB_IMAGE = nil      ; input bits [z][row][col]; nil: all 0
; One compute cycle: (pin start end), as fractions of the period: reset,
; multiply and average, each during one third of the cycle.
TB_CYCLE = '(("RST" 0.0 0.16) ("MULTIPLY" 0.333 0.493) ("AVG" 0.667 0.827))
; PIPELINED: the row-buffer write (WL_IA_<k>) and row selection (SEL_<k>)
; pulse during the multiply phase of each cycle.
TB_ROW_WRITE = '(0.333 0.493)
; PIPELINED: high level of SEL_<k>, as a fraction of TB_VDD. A switch matrix
; that passes the activations through NMOS transistors (as the reference
; SWITCH_MATRIX_3X3_A does) delivers an input +1 at about VDD - Vth at 1.0, so it
; counts less than an input -1; a level of at least 1 + Vth/VDD (a bootstrapped
; select) passes full swing. Simulation only: in silicon, use transmission gates
; or a bootstrapped select driver.
TB_SEL_HIGH = 1.0
; VAVG/VDD = gain x m + offset for a matching fraction m, by architecture:
; (architecture gain offset). The thresholds B_<i>_<f> use it. The values below
; are ideal charge sharing (gain 1, offset 0). Real cells give a lower gain and
; a positive offset: simulate once, read the fit that the OCEAN script prints
; for your cells (lines B2C-TB-CHECK layer ...), enter it here and generate the
; testbench again.
TB_VAVG_TRANSFER = '(("FLASH" 1.0 0.0) ("PIPELINED" 1.0 0.0))
; Optional overrides: (pin "dc" level) or (pin "pulse" low high delay width
; period), levels as fractions of TB_VDD and times in clock periods.
TB_CONTROL = nil
; Spectre model files for the OCEAN script, '(("file" "section") ...). nil
; leaves a line to edit in the script.
TB_MODEL_FILES = nil
; Spectre accuracy preset of the transient: nil (Spectre's default), "liberal"
; (faster, for large networks), "moderate" or "conservative".
TB_ERRPRESET = nil
; Nodes whose waveforms Spectre writes: "selected" (only those the script
; checks) or "allpub" (every node, to plot any of them; large for big networks:
; about 0.8 GB per simulated microsecond for the MNIST PIPELINED network).
TB_SAVE = "selected"
;-------------------------------------------------------------------------------

;------ REPORT ------------------------------------------------------------------
; REPORT = t also writes <working dir>/<library>_report.txt: the cells of the
; network, the area of the components (from their layout views), the
; connections placed, latency, throughput and energy. See Report.il.
REPORT = nil
; Energy drawn from VDDA per mask and compute cycle, J, by architecture:
; '(("FLASH" <J>) ("PIPELINED" <J>)). It depends on your cells: take it from
; line B2C-TB-ENERGY of a generated OCEAN script (a single-layer network is
; enough). nil leaves the energy out of the report.
REPORT_ENERGY_PER_MASK_CYCLE = nil
;-------------------------------------------------------------------------------

; B2C_NO_RUN = t before loading only reads the settings (used by
; examples/quickstart/quickstart.il).
unless( boundp('B2C_NO_RUN) && B2C_NO_RUN
  b2cGenerate(CONFIG))
