# Component cells

BNNtoCMOS builds the network from a small set of circuit cells that it
instantiates by name from one library, `COMPONENT_LIBNAME` in
`skill/MAIN_PARAMETERS.il`. The reference cells used in the paper were designed
in a commercial CMOS process and are not distributed. Any implementation
works if its **symbol** has the pins listed below, with exactly these names.
The libraries that these cells instantiate must be in `cds.lib` too, for
netlisting.
Pin directions are those of the reference cells.

The cell names are settings too (`COMPONENT_SRAM`, `COMPONENT_PRECHARGER`, ...),
so your cells can have other names.

## Both architectures

### `COMPONENT_SRAM` — IMC bitcell (reference: `SRAM_10T1C_V5`)

A 6T SRAM cell extended with XNOR, averaging and reset operations. It stores one
weight bit and multiplies it with one input activation, charging a capacitor.

| Pin | Dir. | Function | Connected by the generator to |
|---|---|---|---|
| `BL`, `BLN` | inout | bit lines | shared by the 9 bitcells of a mask |
| `WL` | input | word line (writes BL/BLN into the cell) | `WL<k>` of the mask, k = 0..8 |
| `AI` | input | input activation | `IA<k>` of the mask, the same k as `WL` |
| `MULTIPLY` | input | XNOR of weight and activation onto the capacitor | common |
| `AVG` | input | shares the charge of the capacitor with `VAVG` | common |
| `RST` | input | resets the capacitor | common |
| `VAVG` | inout | averaging node | shared by all bitcells of a filter |
| `VDDA`, `VSSA` | inout | supply | common |

### `COMPONENT_PRECHARGER` — bit-line precharger (reference: `PRECHARGER`)

| Pin | Dir. | Connected to |
|---|---|---|
| `BL`, `BLN` | inout | mask bit lines |
| `PRECHG` | inout | `PRECHG_W` |
| `VDDA` | inout | supply |

## FLASH only

### `COMPONENT_WRITEDRIVER_FLASH` — weight write driver (reference: `WRITE_DRIVER`)

| Pin | Dir. | Connected to |
|---|---|---|
| `BL`, `BLN` | inout | mask bit lines |
| `D` | input | `D`, the weight bit to write |
| `VDDA`, `VSSA` | inout | supply |

## PIPELINED only

### `COMPONENT_WRITEDRIVER_PIPELINED` — weight and activation write driver (reference: `WRITE_DRIVER_V5`)

Writes either a weight into the bitcells (`BL`/`BLN`) or an input pixel into the
row buffer (`BL_IA`/`BLN_IA`), as selected by `SEL_IA_W`.

| Pin | Dir. | Connected to |
|---|---|---|
| `BL`, `BLN` | inout | mask bit lines |
| `BL_IA`, `BLN_IA` | inout | bit lines of the row buffer |
| `D_W` | input | `D_W`, weight bit |
| `D_IA` | input | `D_IA` of the mask, the input pixel of this column |
| `WR_W_ENABLE` | input | `WR_W_EN` |
| `WR_IA_ENABLE` | input | `WR_IA_ENABLE` |
| `SEL_IA_W` | input | `SEL_IA_W` |
| `VDDA`, `VSSA` | inout | supply |

### `COMPONENT_SRAM_6T` — three-row activation buffer (reference: `SRAM_6T_DUAL_COLUMN`)

Stores the last three pixels of its column, one per image row.

| Pin | Dir. | Connected to |
|---|---|---|
| `WL_IA_0`, `WL_IA_1`, `WL_IA_2` | input | `WL_IA_<n>`, selects the row slot to write |
| `BL_IA`, `BLN_IA` | inout | buffer bit lines (write driver) |
| `PRECHG_IA` | input | `PRECHG_IA` |
| `C_0`, `C_1`, `C_2` | output | the three stored pixels, shared with the neighbouring masks |
| `VDDA`, `VSSA` | inout | supply |

### `COMPONENT_SWITCHMATRIX` — row rotation (reference: `SWITCH_MATRIX_3X3_A`)

Three per mask: one for the left neighbour, one for this column, one for the
right neighbour. Each routes three stored rows to three bitcell inputs, rotating
them with `SEL_0..2` as new rows arrive.

| Pin | Dir. | Connected to |
|---|---|---|
| `C_0`, `C_1`, `C_2` | input | stored rows of the column (`C_0..2`, `C_3..5` or `C_6..8` of the mask) |
| `IA3`, `IA4`, `IA5` | input* | bitcell inputs `IA0..2`, `IA3..5` or `IA6..8` |
| `SEL_0`, `SEL_1`, `SEL_2` | input | common |
| `VSSA` | inout | supply |

\* `IA3..IA5` drive the bitcells but are declared `input` in the reference
symbol, so `schCheck` reports the bitcell inputs as floating. Declaring them
`output` in your cell removes these warnings.

### `COMPONENT_NMOS` — reset transistor (reference: an NMOS of the technology library)

An NMOS transistor from the technology library (`COMPONENT_NMOS_LIBNAME`). It
pulls `VAVG` to `VSSA` while `RST` is high.

| Terminal | Connected to |
|---|---|
| `D` | `VAVG` |
| `G` | `RST` |
| `S`, `B` | `VSSA` |

## Batch-norm cells

The generator makes the batch-norm cells itself, so they need no component.
- **Default:** they have pins only, for you to add your comparator.
- **`BATCHNORM_MODEL = "ahdlLib"`:** they get behavioural cells from Cadence's
  `ahdlLib`, for simulation. Each output gets a `comparator`, a `d_ff`, and in
  PIPELINED cells an `and_gate`.
  This needs `ahdlLib`, which ships with Virtuoso, defined in `cds.lib`.

## For the report

The area estimate (`REPORT = t`) takes the bounding box of each component's
`layout` view, as stored in the library, and multiplies it by the number of
instances. No area is built into BNNtoCMOS: it comes from your layouts. For a
parameterized cell of the technology library (the reset NMOS), the box is that
of the cell's default parameters, not of the instance. Components without a
layout view are listed in the report and
left out of the total.
