#!/bin/sh
# run_quickstart.sh [models.il [DIR]] -- generate the quick-start network and
# simulate both testbenches. DIR selects another network: a directory with
# NETWORK_PARAMETERS.il and TB_IMAGE.il.
# Run it from a directory whose cds.lib defines (see cds.lib.example):
#   - the component library of MAIN_PARAMETERS.il (COMPONENT_LIBNAME), the
#     libraries its cells instantiate, and the library of the reset transistor
#     (COMPONENT_NMOS_LIBNAME);
#   - Cadence's basic, analogLib and ahdlLib;
# with virtuoso and ocean on the PATH. models.il sets TB_MODEL_FILES to your
# Spectre model files (see models.il.example); without it, only the schematics,
# testbenches and reports are generated.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SKILL_DIR=$(cd "$HERE/../../skill" && pwd)
MODELS="${1:+$(cd "$(dirname "$1")" && pwd)/$(basename "$1")}"
NETWORK_DIR="${2:+$(cd "$2" && pwd)}"
# The paths are written into SKILL strings: refuse characters that end them.
for p in "$HERE" "$SKILL_DIR" "$MODELS" "$NETWORK_DIR"; do
  case "$p" in
    *'"'* | *'\'* | *'
'*) echo "run_quickstart.sh: unsupported character in path: $p" >&2; exit 1 ;;
  esac
done
{
  printf 'BNNTOCMOS_DIR = "%s"\n' "$SKILL_DIR"
  if [ -n "$MODELS" ]; then printf 'B2C_MODELS = "%s"\n' "$MODELS"; fi
  if [ -n "$NETWORK_DIR" ]; then printf 'B2C_NETWORK_DIR = "%s"\n' "$NETWORK_DIR"; fi
  printf 'load("%s/quickstart.il")\nexit()\n' "$HERE"
} > quickstart_run.il
virtuoso -nograph -replay quickstart_run.il -log quickstart.log </dev/null >/dev/null 2>&1
grep -E "^\\\\o BNNtoCMOS: (testbench|QUICKSTART)|\\*Error\\*" quickstart.log | sed 's/^\\o //'
if [ -z "$MODELS" ]; then
  echo "No model files: add them to the OCEAN scripts, or rerun with models.il."
  exit 0
fi
for arch in FLASH PIPE; do
  for ocn in QUICKSTART_${arch}_*_TB/*_TB.ocn; do
    echo "== $ocn"
    ocean -nograph < "$ocn" > "${ocn%.ocn}.log" 2>&1 || true
    if grep -q "B2C-TB" "${ocn%.ocn}.log"; then
      grep "B2C-TB" "${ocn%.ocn}.log" | sed "s/^[> ]*//"
    else
      echo "no check output: see ${ocn%.ocn}.log"
    fi
  done
done
