;-------------------------------------------------------------------------------
; quickstart.il -- the quick-start network (NETWORK_PARAMETERS.il, 6x6 image,
; layers of 2 and 4 filters) in both architectures, into the libraries
; QUICKSTART_FLASH and QUICKSTART_PIPE, with:
;   - behavioural batch-norm cells (BATCHNORM_MODEL "ahdlLib"), so that the
;     whole network simulates;
;   - a testbench per architecture, whose OCEAN script checks the simulation
;     against the network (TB_IMAGE.il is the input);
;   - an estimate report per architecture.
; run_quickstart.sh runs it and the simulations. To load it yourself, set
; BNNTOCMOS_DIR to the skill directory first, and optionally:
;   - B2C_MODELS: a file that sets TB_MODEL_FILES (see models.il.example), to
;     get OCEAN scripts that run as they are;
;   - B2C_NETWORK_DIR: another network, a directory with NETWORK_PARAMETERS.il
;     and TB_IMAGE.il.
; Nothing is read from environment variables.
;-------------------------------------------------------------------------------
unless( boundp('BNNTOCMOS_DIR) && stringp(BNNTOCMOS_DIR)
  error("quickstart.il: set BNNTOCMOS_DIR to the skill directory first\n"))
B2C_QUICKSTART = if( boundp('B2C_NETWORK_DIR) && stringp(B2C_NETWORK_DIR)
  B2C_NETWORK_DIR strcat(BNNTOCMOS_DIR "/../examples/quickstart"))
B2C_NO_RUN = t
load(strcat(BNNTOCMOS_DIR "/MAIN_PARAMETERS.il"))
B2C_NO_RUN = nil

NETWORK_FILE = strcat(B2C_QUICKSTART "/NETWORK_PARAMETERS.il")
load(NETWORK_FILE)
load(strcat(B2C_QUICKSTART "/TB_IMAGE.il"))
TB_GENERATE = t
REPORT = t
BATCHNORM_MODEL = "ahdlLib"
when( boundp('B2C_MODELS) && stringp(B2C_MODELS)
  load(B2C_MODELS))
LIBNAME_FLASH = "QUICKSTART_FLASH"
LIBNAME_PIPELINED = "QUICKSTART_PIPE"
b2cGenerate("BOTH")
