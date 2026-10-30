#!/usr/bin/env python3
"""Translate a trained binarized CNN into a SKILL parameter file for BNNtoCMOS.

Reads a Larq/Keras model saved with ``model.save("model.h5")``, or an ONNX
model (exported from PyTorch, or from Keras with tf2onnx; see onnx_reader.py),
and writes a ``.il`` file defining the globals that MAIN_PARAMETERS.il
otherwise sets by hand (IMAGE_HEIGHT, IMAGE_WIDTH, INPUT_DIMENSION, LAYERS),
plus the binarized weights and the batch-norm thresholds of every layer:

    python3 bnn_to_skill.py model.h5 -o NETWORK_PARAMETERS.il
    python3 bnn_to_skill.py model.onnx -o NETWORK_PARAMETERS.il

In MAIN_PARAMETERS.il, delete the hand-written IMAGE_*, INPUT_DIMENSION and
LAYERS lines and load the generated file in their place:

    load("NETWORK_PARAMETERS.il")

Only networks the BNNtoCMOS library can build are accepted: 3x3 convolutions
with stride 1 and "same" padding, each optionally followed by batch
normalization, then optionally flatten + dense layers. Anything else is
reported as an error and nothing is written unless --force is given.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import h5py
import numpy as np

KERNEL = 3
# Bit written into an SRAM cell for weight +1 (and driven on IA for activation +1).
BIT_FOR_PLUS_ONE = 1
# Larq pads "same" convolutions with this value; the circuit ties out-of-image
# inputs to VSSA, i.e. activation -1 under the bit convention above.
CIRCUIT_PAD_VALUE = -1.0 if BIT_FOR_PLUS_ONE == 1 else 1.0
BITS_PER_LINE = 64


def kernel_index(dh: int, dw: int) -> int:
    """Position k of kernel element (row dh, column dw) inside a mask.

    Channel.il labels mask pin IA<k> with k = 3*x + y, x being the column and
    y the row offset in the 3x3 window. Pipelined.il's switch matrices use the
    same order: left column -> IA0..2, centre -> IA3..5, right -> IA6..8.
    """
    return KERNEL * dw + dh


HDF5_SIGNATURE = b"\x89HDF\r\n\x1a\n"


class ModelFileError(Exception):
    """The file is not a Keras HDF5 or ONNX model this script can read."""


@dataclass
class BatchNorm:
    name: str
    gamma: np.ndarray
    beta: np.ndarray
    mean: np.ndarray
    var: np.ndarray
    eps: float


@dataclass
class Conv:
    name: str
    in_channels: int
    filters: int
    signs: np.ndarray  # (3, 3, in_channels, filters), entries +1/-1
    scale: np.ndarray  # per-filter factor of magnitude-aware quantizers, else 1
    bias: np.ndarray | None
    bn: BatchNorm | None = None
    # (theta, invert) of thresholds(), when the reader computed it directly (ONNX)
    folded: tuple[np.ndarray, np.ndarray] | None = None

    @property
    def outputs(self) -> int:
        return self.filters


@dataclass
class Dense:
    name: str
    in_features: int
    units: int
    signs: np.ndarray  # (in_features, units), entries +1/-1
    scale: np.ndarray  # per-unit factor of magnitude-aware quantizers, else 1
    bias: np.ndarray | None
    bn: BatchNorm | None = None
    # (a, b) of affine(), when the reader computed it directly (ONNX)
    folded: tuple[np.ndarray, np.ndarray] | None = None

    @property
    def outputs(self) -> int:
        return self.units


@dataclass
class Network:
    source: Path
    sha256: str
    height: int
    width: int
    channels: int
    convs: list[Conv] = field(default_factory=list)
    dense: list[Dense] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    input_layout: str = "NHWC"  # axis order of the model's input tensor


# --------------------------------------------------------------------------- reading


def _text(value) -> str:
    return value.decode("utf-8") if isinstance(value, bytes) else str(value)


def _pair(value) -> tuple:
    return (value, value) if isinstance(value, int) else tuple(value)


def _read_config(f: h5py.File) -> dict:
    raw = f.attrs.get("model_config")
    if raw is None:
        raise ModelFileError(
            "no model_config attribute: the file holds weights only (model.save_weights). "
            "Save the full model with model.save('model.h5')."
        )
    return json.loads(_text(raw))


def _read_weights(f: h5py.File) -> dict[str, dict[str, np.ndarray]]:
    """Weights of every layer, keyed by short name ('kernel', 'gamma', ...)."""
    root = f["model_weights"] if "model_weights" in f else f
    weights = {}
    for layer in root.attrs.get("layer_names", []):
        group = root[_text(layer)]
        entries = {}
        for full in group.attrs.get("weight_names", []):
            full = _text(full)
            entries[full.rsplit("/", 1)[-1].split(":")[0]] = np.asarray(group[full])
        weights[_text(layer)] = entries
    return weights


def _weight(weights: dict, layer: str, short: str) -> np.ndarray:
    try:
        return weights[layer][short]
    except KeyError:
        raise ModelFileError(f"{layer}: weight '{short}' not found in model_weights") from None


def _inbound_names(node) -> set[str]:
    """Layers feeding a functional-model layer, in Keras 2 or Keras 3 notation."""
    names = set()
    if isinstance(node, dict):
        if "keras_history" in node:
            names.add(node["keras_history"][0])
        for value in node.values():
            names |= _inbound_names(value)
    elif isinstance(node, list):
        if len(node) >= 3 and isinstance(node[0], str) and isinstance(node[1], int):
            names.add(node[0])
        else:
            for item in node:
                names |= _inbound_names(item)
    return names


def _quantizer(q) -> str | None:
    if isinstance(q, dict):
        return q.get("class_name")
    return q


def _is_sign(q) -> bool:
    name = _quantizer(q)
    return name is not None and "sign" in name.lower()


def _input_shape(layers: list[dict], override) -> tuple[int, int, int]:
    if override:
        return tuple(override)
    for layer in layers:
        cfg = layer.get("config", {})
        shape = cfg.get("batch_input_shape") or cfg.get("batch_shape")
        if shape:
            if len(shape) != 4 or None in shape[1:]:
                raise ModelFileError(
                    f"input shape {shape} is not a fixed (batch, H, W, C) image; "
                    "pass --input-shape H W C"
                )
            return tuple(int(s) for s in shape[1:])
    raise ModelFileError("input shape not found in model_config; pass --input-shape H W C")


# --------------------------------------------------------------------------- parsing


def _conv(net, name, kind, cfg, weights, shape) -> Conv | None:
    where = f"{name} ({kind})"
    if len(shape) != 3:
        net.errors.append(f"{where}: convolution after flatten is not supported")
        return None
    checks = [
        (_pair(cfg.get("kernel_size", 0)) == (KERNEL, KERNEL), f"kernel_size {cfg.get('kernel_size')}; the masks are fixed at 3x3"),
        (_pair(cfg.get("strides", 1)) == (1, 1), f"strides {cfg.get('strides')}; only stride 1 is built"),
        (_pair(cfg.get("dilation_rate", 1)) == (1, 1), f"dilation_rate {cfg.get('dilation_rate')} is not supported"),
        (cfg.get("padding") == "same", f"padding '{cfg.get('padding')}'; the circuit keeps W x H and pads, i.e. 'same'"),
        (cfg.get("data_format", "channels_last") == "channels_last", "only channels_last data is supported"),
        (cfg.get("groups", 1) == 1, f"groups {cfg.get('groups')} is not supported"),
    ]
    net.errors.extend(f"{where}: {msg}" for ok, msg in checks if not ok)

    kq, iq = cfg.get("kernel_quantizer"), cfg.get("input_quantizer")
    if not _is_sign(kq):
        net.warnings.append(f"{where}: kernel_quantizer {_quantizer(kq)}; weights binarized by sign anyway")
    if net.convs and not _is_sign(iq):
        net.warnings.append(f"{where}: input_quantizer {_quantizer(iq)}; the circuit only takes binary activations")
    pad = cfg.get("pad_values", 0.0)
    if pad != CIRCUIT_PAD_VALUE:
        net.warnings.append(
            f"{where}: pad_values={pad} but the circuit pads with VSSA (activation {CIRCUIT_PAD_VALUE:+.0f}); "
            f"border pixels will differ from the trained model unless it is retrained with "
            f"pad_values={CIRCUIT_PAD_VALUE}"
        )
    if cfg.get("activation") not in (None, "linear"):
        net.warnings.append(f"{where}: activation '{cfg['activation']}' inside the layer is ignored")

    kernel = _weight(weights, name, "kernel")
    expected = (KERNEL, KERNEL, shape[2], cfg["filters"])
    if kernel.shape != expected:
        net.errors.append(f"{where}: kernel shape {kernel.shape}, expected {expected}")
        return None
    magnitude = _quantizer(kq) and "magnitude" in _quantizer(kq).lower()
    scale = np.mean(np.abs(kernel), axis=(0, 1, 2)) if magnitude else np.ones(kernel.shape[3])
    return Conv(
        name=name,
        in_channels=shape[2],
        filters=cfg["filters"],
        signs=np.where(kernel >= 0, 1, -1).astype(np.int8),
        scale=scale,
        bias=_weight(weights, name, "bias") if cfg.get("use_bias") else None,
    )


def _dense(net, name, kind, cfg, weights, shape) -> Dense | None:
    where = f"{name} ({kind})"
    if len(shape) != 1:
        net.errors.append(f"{where}: dense layer needs a Flatten before it")
        return None
    kq = cfg.get("kernel_quantizer")
    if not _is_sign(kq):
        net.warnings.append(f"{where}: kernel_quantizer {_quantizer(kq)}; weights binarized by sign anyway")
    if not _is_sign(cfg.get("input_quantizer")):
        net.warnings.append(f"{where}: input_quantizer {_quantizer(cfg.get('input_quantizer'))}; the circuit only takes binary activations")
    kernel = _weight(weights, name, "kernel")
    if kernel.shape != (shape[0], cfg["units"]):
        net.errors.append(f"{where}: kernel shape {kernel.shape}, expected {(shape[0], cfg['units'])}")
        return None
    magnitude = _quantizer(kq) and "magnitude" in _quantizer(kq).lower()
    return Dense(
        name=name,
        in_features=shape[0],
        units=cfg["units"],
        signs=np.where(kernel >= 0, 1, -1).astype(np.int8),
        scale=np.mean(np.abs(kernel), axis=0) if magnitude else np.ones(kernel.shape[1]),
        bias=_weight(weights, name, "bias") if cfg.get("use_bias") else None,
    )


def _batch_norm(net, name, cfg, weights, shape, previous) -> None:
    if previous is None or previous.bn is not None:
        net.errors.append(f"{name}: batch normalization must directly follow a conv or dense layer")
        return
    axis = cfg.get("axis", -1)
    if isinstance(axis, list):
        axis = axis[0] if len(axis) == 1 else None
    if axis not in (-1, len(shape)):
        net.errors.append(f"{name}: normalizes axis {cfg.get('axis')}, only the channel axis is supported")
        return
    n = previous.outputs
    layer = weights.get(name, {})
    previous.bn = BatchNorm(
        name=name,
        gamma=layer.get("gamma", np.ones(n)),
        beta=layer.get("beta", np.zeros(n)),
        mean=_weight(weights, name, "moving_mean"),
        var=_weight(weights, name, "moving_variance"),
        eps=float(cfg.get("epsilon", 1e-3)),
    )


def _parse_h5(path: Path, input_shape=None) -> Network:
    with h5py.File(path, "r") as f:
        config = _read_config(f)
        weights = _read_weights(f)
    inner = config.get("config", config)
    layers = inner if isinstance(inner, list) else inner.get("layers")
    if not layers:
        raise ModelFileError("model_config has no layer list")

    h, w, c = _input_shape(layers, input_shape)
    net = Network(path, hashlib.sha256(path.read_bytes()).hexdigest(), h, w, c)
    shape: tuple = (h, w, c)  # activation shape without the batch axis
    previous = None  # last Conv/Dense, which a batch norm attaches to
    previous_name = None
    sequential = config.get("class_name") == "Sequential"

    for layer in layers:
        kind = layer["class_name"]
        cfg = layer.get("config", {})
        name = cfg.get("name") or layer.get("name")
        if not sequential and kind != "InputLayer":
            inbound = _inbound_names(layer.get("inbound_nodes", []))
            if inbound != {previous_name}:
                net.errors.append(f"{name}: fed by {sorted(inbound)}; only plain layer chains are supported")
        previous_name = name

        if kind == "InputLayer" or kind in ("Dropout", "SpatialDropout2D"):
            continue
        if kind in ("QuantConv2D", "Conv2D"):
            conv = _conv(net, name, kind, cfg, weights, shape)
            if conv:
                net.convs.append(conv)
                shape, previous = (shape[0], shape[1], conv.filters), conv
        elif kind in ("QuantDense", "Dense"):
            dense = _dense(net, name, kind, cfg, weights, shape)
            if dense:
                net.dense.append(dense)
                shape, previous = (dense.units,), dense
        elif kind == "BatchNormalization":
            _batch_norm(net, name, cfg, weights, shape, previous)
        elif kind == "Flatten":
            shape = (int(np.prod(shape)),)
        elif kind == "Activation":
            if not (len(shape) == 1 and cfg.get("activation") in ("softmax", "linear")):
                net.warnings.append(f"{name}: activation '{cfg.get('activation')}' is ignored")
        elif "Pooling" in kind:
            net.errors.append(f"{name} ({kind}): the circuit library has no pooling")
        else:
            net.errors.append(f"{name} ({kind}): layer type not supported")
    return net


def _parse_onnx(path: Path) -> Network:
    import onnx_reader  # needs the onnx package, which HDF5 users do not

    try:
        model = onnx_reader.read(path)
    except onnx_reader.OnnxError as e:
        raise ModelFileError(str(e)) from None
    net = Network(path, hashlib.sha256(path.read_bytes()).hexdigest(),
                  model.height, model.width, model.channels, input_layout=model.layout)
    for layer in model.layers:
        if layer.kind == "conv":
            net.convs.append(Conv(layer.name, layer.signs.shape[2], layer.signs.shape[3], layer.signs,
                                  layer.scale, layer.bias, folded=layer.folded))
        else:
            net.dense.append(Dense(layer.name, layer.signs.shape[0], layer.signs.shape[1], layer.signs,
                                   layer.scale, layer.bias, folded=layer.folded))
    net.errors += model.errors
    net.warnings += model.warnings
    return net


def parse(path: Path, input_shape=None) -> Network:
    """Read a Keras HDF5 or an ONNX model, recognized by its content."""
    with open(path, "rb") as f:
        hdf5 = f.read(len(HDF5_SIGNATURE)) == HDF5_SIGNATURE
    if hdf5:
        net = _parse_h5(path, input_shape)
    else:
        net = _parse_onnx(path)
        if input_shape:
            net.warnings.append("--input-shape is ignored for ONNX models, which record the input size")

    if net.dense:
        net.warnings.append(
            f"{net.dense[0].name}: fully connected layers go to FC_WEIGHTS, but the SKILL generator "
            "does not build FC hardware yet"
        )
    if not net.convs:
        net.errors.append("no convolution layers found")
    for filters, count in Counter(conv.filters for conv in net.convs).items():
        if count > 1:
            net.errors.append(
                f"{count} conv layers have {filters} filters; layer and batch-norm cells are named "
                f"after the filter count (SKILL_*_LAYER_*_{filters}), so they would overwrite each other"
            )
    return net


# --------------------------------------------------------------------------- derived data


def conv_bits(conv: Conv) -> np.ndarray:
    """Bits [z][f][k] for layer pins WL_<z>_<f>_<k>."""
    bits = np.empty((conv.in_channels, conv.filters, KERNEL * KERNEL), dtype=np.int8)
    for dh in range(KERNEL):
        for dw in range(KERNEL):
            plus = conv.signs[dh, dw] > 0  # (in_channels, filters)
            bits[:, :, kernel_index(dh, dw)] = np.where(plus, BIT_FOR_PLUS_ONE, 1 - BIT_FOR_PLUS_ONE)
    return bits


def thresholds(conv: Conv) -> tuple[np.ndarray, np.ndarray]:
    """Fold bias, batch norm and sign into a threshold on the matching fraction.

    Filter f sums N = 9*C binary products, s = 2*m*N - N for a fraction m of
    matching (XNOR = 1) cells; charge sharing over the filter's cells puts
    m*VDDA on VAVG. The layer computes x = scale*s + bias, and batch norm plus
    sign output 1 when gamma*(x - mean)/sqrt(var + eps) + beta >= 0. Returns
    (theta, invert) per filter: the output is m >= theta, or m <= theta where
    invert is True. A theta outside [0, 1] means a constant output.
    """
    if conv.folded is not None:
        return conv.folded
    n = KERNEL * KERNEL * conv.in_channels
    bias = conv.bias if conv.bias is not None else np.zeros(conv.filters)
    if conv.bn is None:
        x0, gamma = np.zeros(conv.filters), np.ones(conv.filters)
    else:
        bn = conv.bn
        gamma = bn.gamma
        sigma = np.sqrt(bn.var + bn.eps)
        with np.errstate(divide="ignore", invalid="ignore"):
            x0 = bn.mean - bn.beta * sigma / gamma
    s0 = (x0 - bias) / conv.scale
    theta = (s0 + n) / (2 * n)
    if conv.bn is not None:
        always_on = conv.bn.beta >= 0
        theta = np.where(gamma == 0, np.where(always_on, -1.0, 2.0), theta)
    return theta, gamma < 0


def affine(layer: Conv | Dense) -> tuple[np.ndarray, np.ndarray]:
    """Per-output (a, b) such that the layer output after batch norm is a*s + b,
    s being the +-1 dot product. For a final dense layer, argmax(a*s + b) is the
    predicted class."""
    if layer.folded is not None:
        return layer.folded
    bias = layer.bias if layer.bias is not None else np.zeros(layer.outputs)
    if layer.bn is None:
        return layer.scale.astype(float), bias.astype(float)
    bn = layer.bn
    k = bn.gamma / np.sqrt(bn.var + bn.eps)
    return k * layer.scale, k * (bias - bn.mean) + bn.beta


def device_counts(net: Network) -> dict[str, int]:
    channels = sum(conv.in_channels * conv.filters for conv in net.convs)
    cells = KERNEL * KERNEL
    return {
        "channels": channels,
        "flash_masks": channels * net.height * net.width,
        "flash_cells": channels * net.height * net.width * cells,
        "pipelined_masks": channels * net.width,
        "pipelined_cells": channels * net.width * cells,
    }


# --------------------------------------------------------------------------- SKILL output

_NAME_UNSAFE = re.compile(r"[^A-Za-z0-9_.:/+-]")
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def safe_name(text, limit: int = 80) -> str:
    """A name from the model (layer or file name) as it may appear in the output.

    The names come from the model file, so whoever made the file chooses them.
    In a SKILL comment, a newline would end the comment and put the rest of the
    name into the parameter file as code, which Virtuoso runs when it loads the
    file. Only letters, digits and _ . : / + - are kept; the rest become _.
    """
    text = _NAME_UNSAFE.sub("_", str(text))
    return text if len(text) <= limit else text[: limit - 3] + "..."


def terminal_safe(text) -> str:
    """text without control characters, for messages on the terminal."""
    return _CONTROL.sub("?", str(text))



def _bit_lines(bits, indent: str) -> list[str]:
    text = [str(int(b)) for b in bits]
    if len(text) <= BITS_PER_LINE:
        return [f"{indent}({' '.join(text)})"]
    chunks = [" ".join(text[i : i + BITS_PER_LINE]) for i in range(0, len(text), BITS_PER_LINE)]
    return [f"{indent}({chunks[0]}"] + [f"{indent} {chunk}" for chunk in chunks[1:-1]] + [f"{indent} {chunks[-1]})"]


def printable_thresholds(theta: np.ndarray, invert: np.ndarray, n: int) -> np.ndarray:
    """Thresholds as written to the file (6 decimals), moved to halfway between
    two levels of the matching fraction m = 0, 1/n, ..., 1 wherever rounding
    would change the output of the filter at one of them."""
    m = np.arange(n + 1) / n
    out = []
    for t, inv in zip(theta, invert):
        rounded = float(f"{t:.6f}")
        on = m <= t if inv else m >= t
        if np.array_equal(on, m <= rounded if inv else m >= rounded):
            out.append(t)
            continue
        if inv:  # outputs 1 up to level j
            j = np.flatnonzero(on)[-1] if on.any() else -1
            out.append(1 + 0.5 / n if j == n else (-0.5 / n if j < 0 else (m[j] + m[j + 1]) / 2))
        else:  # outputs 1 from level i
            i = np.flatnonzero(on)[0] if on.any() else n + 1
            out.append(-0.5 / n if i == 0 else (1 + 0.5 / n if i > n else (m[i - 1] + m[i]) / 2))
    return np.array(out)


def to_skill(net: Network, output_name: str) -> str:
    out = [
        f"; {safe_name(output_name)} -- generated by bnn_to_skill.py from {safe_name(net.source.name)}",
        f"; (sha256 {net.sha256[:16]}, {date.today().isoformat()}). Regenerate it instead of editing.",
        ";",
        "; Network shape for MAIN_PARAMETERS.il: load this file in place of the",
        "; hand-written IMAGE_*, INPUT_DIMENSION and LAYERS settings.",
        "",
        f"IMAGE_HEIGHT = {net.height}",
        f"IMAGE_WIDTH = {net.width}",
        f"INPUT_DIMENSION = {net.channels}",
        f"LAYERS = '({' '.join(str(conv.filters) for conv in net.convs)}) ; filters per conv layer",
        "",
        f"; Binarized conv weights, one bit per SRAM cell ({BIT_FOR_PLUS_ONE} = weight +1).",
        "; nth(k nth(f nth(z nth(l WEIGHTS)))) is the bit on pin WL_<z>_<f>_<k> of conv",
        "; layer l, where k = 3*column + row inside the 3x3 window.",
        "WEIGHTS = list(",
    ]
    for l, conv in enumerate(net.convs):
        out.append(f"  ; layer {l} '{safe_name(conv.name)}': 3x3x{conv.in_channels} -> {conv.filters} filters")
        out.append("  '(")
        for z, per_filter in enumerate(conv_bits(conv)):
            out.append(f"    ( ; z = {z}")
            for f, bits in enumerate(per_filter):
                out.append(f"{_bit_lines(bits, '      ')[0]} ; f = {f}")
            out.append("    )")
        out.append("  )")
    out.append(")")

    out += [
        "",
        "; Bias + batch norm + sign of each filter, folded into a threshold on the",
        "; fraction m of matching cells (VAVG/VDDA for ideal charge sharing over the",
        "; 9*C cells of the filter): output 1 when m >= theta, or m <= theta where",
        "; BN_INVERT is t. A theta outside [0, 1] means the output is constant.",
        "BN_THRESHOLD = list(",
    ]
    inverts = []
    for conv in net.convs:
        theta, invert = thresholds(conv)
        theta = printable_thresholds(theta, invert, KERNEL * KERNEL * conv.in_channels)
        out.append(f"  '({' '.join(f'{v:.6f}' for v in theta)}) ; {safe_name(conv.name)}")
        inverts.append(f"  '({' '.join('t' if i else 'nil' for i in invert)}) ; {safe_name(conv.name)}")
    out += [")", "BN_INVERT = list(", *inverts, ")"]

    out += [
        "",
        "; Fully connected layers (not built by the SKILL generator yet). FC_LAYERS",
        "; holds (inputs outputs) per layer; FC_WEIGHTS[l][unit] lists the input bits",
        "; in Keras flatten order, index = (row*IMAGE_WIDTH + column)*channels + channel.",
        "; With s the +-1 dot product of a unit, its output after bias and batch norm is",
        "; FC_SCALE*s + FC_OFFSET: binarized by sign between layers, argmax at the end.",
        f"FC_LAYERS = '({' '.join(f'({d.in_features} {d.units})' for d in net.dense)})",
        "FC_WEIGHTS = list(",
    ]
    for d in net.dense:
        out += [f"  ; '{safe_name(d.name)}'", "  '("]
        bits = np.where(d.signs > 0, BIT_FOR_PLUS_ONE, 1 - BIT_FOR_PLUS_ONE)
        for unit in range(d.units):
            out += _bit_lines(bits[:, unit], "    ")
        out.append("  )")
    out.append(")")
    for label, index in (("FC_SCALE", 0), ("FC_OFFSET", 1)):
        out.append(f"{label} = list(")
        for d in net.dense:
            out.append(f"  '({' '.join(f'{v:.6f}' for v in affine(d)[index])}) ; {safe_name(d.name)}")
        out.append(")")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- CLI


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("model", type=Path, help="Keras HDF5 file saved with model.save(), or ONNX model")
    parser.add_argument("-o", "--output", type=Path, default=Path("NETWORK_PARAMETERS.il"))
    parser.add_argument("--input-shape", nargs=3, type=int, metavar=("H", "W", "C"),
                        help="image size, if an HDF5 model does not record it")
    parser.add_argument("--force", action="store_true",
                        help="write the file even if the network has layers the circuit cannot build")
    args = parser.parse_args(argv)

    try:
        net = parse(args.model, args.input_shape)
    except (OSError, ModelFileError) as e:
        print(terminal_safe(f"error: {args.model}: {e}"), file=sys.stderr)
        return 2

    counts = device_counts(net)
    print(f"{args.model}: {net.height}x{net.width}x{net.channels} input, "
          f"conv filters {[conv.filters for conv in net.convs]}, {len(net.dense)} dense layer(s)", file=sys.stderr)
    print(f"  {counts['channels']} channels -> FLASH {counts['flash_masks']:,} masks / {counts['flash_cells']:,} cells, "
          f"PIPELINED {counts['pipelined_masks']:,} masks / {counts['pipelined_cells']:,} cells", file=sys.stderr)
    for message in net.warnings:
        print(terminal_safe(f"warning: {message}"), file=sys.stderr)
    for message in net.errors:
        print(terminal_safe(f"error: {message}"), file=sys.stderr)
    if net.errors and not args.force:
        print("nothing written; fix the model or pass --force", file=sys.stderr)
        return 1

    args.output.write_text(to_skill(net, args.output.name))
    print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
