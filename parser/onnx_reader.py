"""ONNX models for bnn_to_skill.py.

ONNX exporters describe the same binarized network in different ways. tf2onnx
(Keras/Larq) fuses batch norm into the convolution weights, keeps NHWC tensors
with Transposes around each Conv and writes Larq's sign as Sign -> Add -> Sign;
torch.onnx keeps BatchNormalization nodes and NCHW tensors, and writes a
straight-through estimator as x + (sign(x) - x). Instead of matching such
patterns, the reader:

1. Evaluates every node that does not depend on the input image, so the weights
   of each Conv, Gemm and MatMul become constant tensors. They must be binary:
   +-a for all the weights of an output channel, with a > 0.
2. Splits the graph at these layers. In between, only element-wise operators,
   Transpose, Reshape, Flatten and Pad are allowed, plus Softmax, LogSoftmax or
   ArgMax at the end. Pooling, branches and other operators are errors.
3. Runs each piece in between with numpy on probe tensors. A binary layer
   computes y = a*s + b, where s is the +-1 dot product, so running the piece
   at every value s can take gives the exact activation of each filter, which
   must be a threshold on s: this gives BN_THRESHOLD and BN_INVERT. After the
   last dense layer, the piece must be affine in s: FC_SCALE and FC_OFFSET. The
   same probes find the input layout, the padding value and the order in which
   Flatten lists the features.
"""
from __future__ import annotations

import functools
import math
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

try:
    import onnx
    from onnx import numpy_helper
except ImportError:  # pragma: no cover - depends on the environment
    raise ImportError("reading ONNX models needs the onnx package: pip install onnx") from None

KERNEL = 3
LINEAR = {"Conv", "Gemm", "MatMul"}
# Operators that keep the arg max of the classifier output: the network ends there.
TERMINAL = {"Softmax", "LogSoftmax", "ArgMax", "Hardmax"}
POOLING = {"MaxPool", "AveragePool", "GlobalMaxPool", "GlobalAveragePool", "LpPool", "GlobalLpPool"}
LAYOUT = {"Transpose", "Reshape", "Flatten", "Pad"}
PROBE_ELEMENTS = 4_000_000  # largest probe tensor, in elements


class OnnxError(Exception):
    """The file is not an ONNX model with a single image input."""


class Unsupported(Exception):
    """The network has a part the circuit cannot build."""


class _NotBinary(Exception):
    pass


@dataclass
class Layer:
    kind: str  # "conv" or "dense"
    name: str
    signs: np.ndarray  # conv: (3, 3, C, F) as in Keras; dense: (inputs, units), inputs in Keras flatten order
    scale: np.ndarray  # magnitude a of the binary weights of each output
    bias: np.ndarray
    folded: tuple | None = None  # conv: (theta, invert); dense: (a, b) of the output a*s + b


@dataclass
class Model:
    height: int = 0
    width: int = 0
    channels: int = 0
    layout: str = ""
    layers: list[Layer] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- operators


def _attrs(node) -> dict:
    out = {}
    for a in node.attribute:
        value = onnx.helper.get_attribute_value(a)
        if isinstance(value, onnx.TensorProto):
            value = numpy_helper.to_array(value)
        elif isinstance(value, bytes):
            value = value.decode()
        out[a.name] = value
    return out


def _ints(x) -> list[int]:
    return [int(v) for v in np.asarray(x).ravel()]


def _div(a, b):
    if np.issubdtype(np.result_type(a, b), np.integer):
        return np.trunc(a / b).astype(np.result_type(a, b))
    return a / b


_UNARY = {
    "Identity": lambda x: x, "Sign": np.sign, "Neg": np.negative, "Abs": np.abs,
    "Relu": lambda x: np.maximum(x, 0), "Sqrt": np.sqrt, "Reciprocal": lambda x: 1 / x,
    "Exp": np.exp, "Log": np.log, "Tanh": np.tanh, "Sigmoid": lambda x: 1 / (1 + np.exp(-x)),
    "Floor": np.floor, "Ceil": np.ceil, "Round": np.round, "Not": np.logical_not,
    "Softsign": lambda x: x / (1 + np.abs(x)), "Softplus": lambda x: np.log1p(np.exp(x)),
    "Erf": np.vectorize(math.erf, otypes=[np.float64]),
}
_BINARY = {
    "Add": np.add, "Sub": np.subtract, "Mul": np.multiply, "Div": _div, "Pow": np.power,
    "Equal": np.equal, "Greater": np.greater, "GreaterOrEqual": np.greater_equal,
    "Less": np.less, "LessOrEqual": np.less_equal,
    "And": np.logical_and, "Or": np.logical_or, "Xor": np.logical_xor,
}
_VARIADIC = {"Max": np.maximum, "Min": np.minimum, "Sum": np.add}
ELEMENTWISE = set(_UNARY) | set(_BINARY) | set(_VARIADIC) | {
    "Mean", "Clip", "LeakyRelu", "Elu", "Selu", "HardSigmoid", "HardSwish", "ThresholdedRelu",
    "Cast", "Where", "Dropout", "BatchNormalization",
    "BipolarQuant",  # QONNX (Brevitas, FINN): sign with sign(0) = +1, times a scale
}


def _pad_widths(node, args, ndim: int, opset: int) -> tuple[list, float, str]:
    at = _attrs(node)
    if opset >= 11:
        pads = _ints(args[1])
        value = args[2] if len(args) > 2 else None
        axes = args[3] if len(args) > 3 else None
    else:
        pads, value, axes = list(at["pads"]), at.get("value", 0.0), None
    value = 0.0 if value is None or np.size(value) == 0 else np.asarray(value).ravel()[0]
    axes = list(range(ndim)) if axes is None else [a % ndim for a in _ints(axes)]
    widths = [(0, 0)] * ndim
    for i, axis in enumerate(axes):
        widths[axis] = (pads[i], pads[i + len(axes)])
    return widths, value, at.get("mode", "constant")


def _compute(node, args: list, opset: int) -> list:
    """Outputs of node for the numpy arrays args (None for an absent input)."""
    op, at = node.op_type, _attrs(node)
    x = args[0] if args else None

    def arg(i):
        return args[i] if i < len(args) else None

    if op in _UNARY:
        return [_UNARY[op](x)]
    if op in _BINARY:
        return [_BINARY[op](x, args[1])]
    if op in _VARIADIC:
        return [functools.reduce(_VARIADIC[op], args)]
    if op == "Mean":
        return [sum(args) / len(args)]
    if op == "Constant":
        for key, dtype in (("value", None), ("value_float", np.float32), ("value_floats", np.float32),
                           ("value_int", np.int64), ("value_ints", np.int64)):
            if key in at:
                return [np.asarray(at[key], dtype=dtype)]
        raise NotImplementedError("Constant without a numeric value")
    if op == "Cast":
        return [x.astype(onnx.helper.tensor_dtype_to_np_dtype(at["to"]))]
    if op == "Clip":
        lo, hi = (arg(1), arg(2)) if opset >= 11 else (at.get("min"), at.get("max"))
        y = x if lo is None else np.maximum(x, lo)
        return [(y if hi is None else np.minimum(y, hi)).astype(x.dtype)]
    if op == "LeakyRelu":
        return [np.where(x >= 0, x, at.get("alpha", 0.01) * x)]
    if op == "Elu":
        return [np.where(x >= 0, x, at.get("alpha", 1.0) * (np.exp(x) - 1))]
    if op == "Selu":
        alpha, gamma = at.get("alpha", 1.67326319217681884765625), at.get("gamma", 1.05070102214813232421875)
        return [gamma * np.where(x > 0, x, alpha * (np.exp(x) - 1))]
    if op == "HardSigmoid":
        return [np.clip(at.get("alpha", 0.2) * x + at.get("beta", 0.5), 0, 1)]
    if op == "HardSwish":
        return [x * np.clip(x / 6 + 0.5, 0, 1)]
    if op == "ThresholdedRelu":
        return [np.where(x > at.get("alpha", 1.0), x, 0)]
    if op == "Where":
        return [np.where(args[0], args[1], args[2])]
    if op == "BipolarQuant":
        return [np.where(x >= 0, 1.0, -1.0).astype(x.dtype) * args[1]]
    if op == "Dropout":
        return [x, np.ones(x.shape, bool)]
    if op == "BatchNormalization":
        shape = (1, -1) + (1,) * (x.ndim - 2)
        scale, bias, mean, var = (np.reshape(a, shape) for a in args[1:5])
        return [(x - mean) / np.sqrt(var + at.get("epsilon", 1e-5)) * scale + bias]
    if op == "Transpose":
        return [np.transpose(x, at.get("perm"))]
    if op == "Reshape":
        shape = _ints(args[1])
        if not at.get("allowzero", 0):
            shape = [x.shape[i] if s == 0 else s for i, s in enumerate(shape)]
        return [x.reshape(shape)]
    if op == "Flatten":
        axis = at.get("axis", 1) % max(x.ndim, 1)
        return [x.reshape(int(np.prod(x.shape[:axis])), -1)]
    if op in ("Squeeze", "Unsqueeze"):
        axes = _ints(arg(1)) if arg(1) is not None else at.get("axes")
        if op == "Squeeze":
            return [np.squeeze(x) if axes is None else np.squeeze(x, axis=tuple(axes))]
        ndim = x.ndim + len(axes)
        for axis in sorted(a % ndim for a in axes):
            x = np.expand_dims(x, axis)
        return [x]
    if op == "Concat":
        return [np.concatenate(args, axis=at["axis"])]
    if op == "Shape":
        return [np.array(x.shape, np.int64)[at.get("start", 0):at.get("end")]]
    if op == "Size":
        return [np.array(x.size, np.int64)]
    if op == "Gather":
        return [np.take(x, args[1], axis=at.get("axis", 0))]
    if op == "Slice":
        if opset >= 10:
            starts, ends, axes, steps = args[1], args[2], arg(3), arg(4)
        else:
            starts, ends, axes, steps = at["starts"], at["ends"], at.get("axes"), None
        starts, ends = _ints(starts), _ints(ends)
        axes = _ints(axes) if axes is not None else list(range(len(starts)))
        steps = _ints(steps) if steps is not None else [1] * len(starts)
        index = [slice(None)] * x.ndim
        for start, end, axis, step in zip(starts, ends, axes, steps):
            index[axis] = slice(start, end, step)
        return [x[tuple(index)]]
    if op == "ConstantOfShape":
        value = np.asarray(at.get("value", np.zeros(1, np.float32)))
        return [np.full(_ints(x), value.ravel()[0], dtype=value.dtype)]
    if op == "Expand":
        return [x * np.ones(_ints(args[1]), dtype=x.dtype)]
    if op == "Range":
        return [np.arange(args[0], args[1], args[2])]
    if op == "Pad":
        widths, value, mode = _pad_widths(node, args, x.ndim, opset)
        if mode != "constant" or min(min(w) for w in widths) < 0:
            raise NotImplementedError(f"Pad mode '{mode}' or negative padding")
        return [np.pad(x, widths, constant_values=value)]
    if op in ("ReduceMean", "ReduceSum", "ReduceMax", "ReduceMin", "ReduceProd", "ReduceL1", "ReduceL2"):
        axes = arg(1) if arg(1) is not None else at.get("axes")
        if axes is None or np.size(axes) == 0:
            if at.get("noop_with_empty_axes", 0):
                return [x]
            axes = None
        else:
            axes = tuple(_ints(axes))
        keep = bool(at.get("keepdims", 1))
        value = {"ReduceMean": np.mean, "ReduceSum": np.sum, "ReduceMax": np.max, "ReduceMin": np.min,
                 "ReduceProd": np.prod}.get(op)
        if value is not None:
            return [np.asarray(value(x, axis=axes, keepdims=keep)).astype(x.dtype)]
        y = np.sum(np.abs(x) if op == "ReduceL1" else x * x, axis=axes, keepdims=keep)
        return [np.asarray(y if op == "ReduceL1" else np.sqrt(y)).astype(x.dtype)]
    if op == "MatMul":
        return [np.matmul(x, args[1])]
    raise NotImplementedError(f"operator {op}")


# --------------------------------------------------------------------------- graph


def _name(node) -> str:
    return node.name or node.output[0]


def _sorted_nodes(nodes, available: set) -> list:
    done, order, pending = set(available), [], list(nodes)
    while pending:
        rest = [n for n in pending if not all(not i or i in done for i in n.input)]
        ready = [n for n in pending if all(not i or i in done for i in n.input)]
        if not ready:
            raise OnnxError(f"node {_name(rest[0])} reads a tensor that no node produces")
        for n in ready:
            order.append(n)
            done.update(n.output)
        pending = rest
    return order


@dataclass
class _Segment:
    source: str  # the input image or the output of a layer
    nodes: list  # the operators between it and the next layer
    end: object | None  # the next layer (Conv, Gemm, MatMul), a TERMINAL node, or None


class _Graph:
    def __init__(self, model):
        graph = model.graph
        self.opset = next((o.version for o in model.opset_import if o.domain in ("", "ai.onnx")), 1)
        self.consts = {t.name: numpy_helper.to_array(t) for t in graph.initializer}
        inputs = [i for i in graph.input if i.name not in self.consts]
        if len(inputs) != 1:
            raise OnnxError(f"the model has {len(inputs)} inputs; BNNtoCMOS needs a single image input")
        self.input = inputs[0]
        self.outputs = [o.name for o in graph.output]
        self.nodes = _sorted_nodes(graph.node, set(self.consts) | {self.input.name})
        # Fold everything that does not depend on the image; keep what depends on it.
        self.dynamic = {self.input.name}
        for node in self.nodes:
            if any(i in self.dynamic for i in node.input):
                self.dynamic.update(node.output)
            elif all(not i or i in self.consts for i in node.input):
                try:
                    outs = _compute(node, [self.consts[i] if i else None for i in node.input], self.opset)
                except Exception:
                    continue  # not computable here; a layer that needs it reports the error
                self.consts.update((name, value) for name, value in zip(node.output, outs) if name)

    def const(self, name: str, where: str) -> np.ndarray:
        if name in self.consts:
            return np.asarray(self.consts[name], dtype=np.float64)
        raise Unsupported(f"{where}: its weights are not constant (they depend on the image, "
                          "or on an operator the reader cannot evaluate)")

    def segment(self, source: str) -> _Segment:
        """The operators from source up to the next layer."""
        tensors, nodes, ends = {source}, [], []
        for node in self.nodes:
            if not any(i in tensors for i in node.input):
                continue
            where = f"{_name(node)} ({node.op_type})"
            if any(i in self.dynamic and i not in tensors for i in node.input):
                raise Unsupported(f"{where}: combines the outputs of different layers; only plain chains of "
                                  "layers are supported (no branches or skip connections)")
            if node.op_type in LINEAR or node.op_type in TERMINAL:
                if node.op_type in LINEAR and node.input[0] not in tensors:
                    raise Unsupported(f"{where}: its weights depend on the image")
                ends.append(node)
                continue
            nodes.append(node)
            tensors.update(o for o in node.output if o)
        if len(ends) > 1:
            raise Unsupported(f"{_name(ends[0])} and {_name(ends[1])} both read the same layer output; "
                              "only plain chains of layers are supported")
        if not ends and not any(o in tensors for o in self.outputs):
            raise Unsupported(f"the tensor {source} does not lead to the network output")
        return _Segment(source, nodes, ends[0] if ends else None)

    def run(self, seg: _Segment, value: np.ndarray, labels: tuple, strict: bool = True):
        """Evaluate seg for value, whose axes are labelled N, C, H, W (or N, C for a
        vector). Returns the tensor at the end of seg with its axis labels, and the
        padding (begin, end) added to each labelled axis. A Flatten turns the labels
        into (N, ("flat", <labels in feature order>))."""
        env = {seg.source: (value, tuple(labels))}
        pads = {}
        for node in seg.nodes:
            op, where = node.op_type, f"{_name(node)} ({node.op_type})"
            args, data = [], []
            for name in node.input:
                if not name:
                    args.append(None)
                elif name in env:
                    args.append(env[name][0])
                    if env[name][1] is not None:
                        data.append(env[name])
                elif name in self.consts:
                    args.append(self.consts[name])
                else:
                    raise Unsupported(f"{where}: input {name} cannot be evaluated")
            if data:  # carries pixels: only operators the circuit can absorb
                if op in POOLING:
                    raise Unsupported(f"{where}: the circuit library has no pooling")
                if op not in ELEMENTWISE and op not in LAYOUT and op not in ("Shape", "Size"):
                    raise Unsupported(f"{where}: not supported between layers (only element-wise operators, "
                                      "Transpose, Reshape, Flatten and Pad)")
                if any(lab != data[0][1] for _, lab in data[1:]):
                    raise Unsupported(f"{where}: combines tensors with different axis orders")
            try:
                outs = _compute(node, args, self.opset)
            except NotImplementedError as e:
                raise Unsupported(f"{where}: {e} is not supported") from None
            except Exception as e:
                raise Unsupported(f"{where}: cannot be evaluated ({e})") from None
            out_labels = [None] * len(outs)
            if data and op not in ("Shape", "Size"):
                x, lab = data[0]
                if op == "Transpose":
                    perm = _attrs(node).get("perm") or list(reversed(range(x.ndim)))
                    out_labels[0] = tuple(lab[p] for p in perm)
                elif op in ("Reshape", "Flatten"):
                    out_labels[0] = _reshape_labels(where, x.shape, outs[0].shape, lab, pads)
                elif op == "Pad":
                    out_labels[0] = lab
                    for axis, (begin, end) in zip(lab, _pad_widths(node, args, x.ndim, self.opset)[0]):
                        if begin or end:
                            if strict and axis not in ("H", "W"):
                                raise Unsupported(f"{where}: pads the {axis} axis")
                            old = pads.get(axis, (0, 0))
                            pads[axis] = (old[0] + begin, old[1] + end)
                else:
                    if outs[0].shape != x.shape:
                        raise Unsupported(f"{where}: broadcasts the layer output from {list(x.shape)} "
                                          f"to {list(outs[0].shape)}")
                    if op == "BatchNormalization" and strict and lab[1] != "C":
                        raise Unsupported(f"{where}: normalizes the {lab[1]} axis instead of the channels")
                    out_labels[0] = lab
            env.update((name, (v, lab)) for name, v, lab in zip(node.output, outs, out_labels) if name)

        if seg.end is not None:
            end = seg.end.input[0]
        else:
            end = next(o for o in self.outputs if o in env)
        value, labels = env[end]
        if labels is None:
            raise Unsupported(f"{end}: the network output does not carry the layer output")
        return value, labels, pads


def _reshape_labels(where, in_shape, out_shape, labels, pads) -> tuple:
    in_shape, out_shape = tuple(in_shape), tuple(out_shape)
    if in_shape == out_shape:
        return labels
    flat = any(isinstance(lab, tuple) for lab in labels)
    if len(in_shape) >= 3 and len(out_shape) == 2 and out_shape[0] == in_shape[0] and not flat:
        if pads:
            raise Unsupported(f"{where}: flattens a padded tensor")
        return (labels[0], ("flat",) + tuple(labels[1:]))
    # A reshape that only moves axes of size 1 is a transpose (tf2onnx writes
    # NHWC -> NCHW this way for one-channel images).
    if len(in_shape) == len(out_shape) and [n for n in in_shape if n != 1] == [n for n in out_shape if n != 1]:
        ones = iter([lab for lab, n in zip(labels, in_shape) if n == 1])
        others = iter([lab for lab, n in zip(labels, in_shape) if n != 1])
        return tuple(next(ones) if n == 1 else next(others) for n in out_shape)
    raise Unsupported(f"{where}: reshapes {list(in_shape)} to {list(out_shape)}")


def _split(value, labels, pads, sizes):
    """(interior, border) of a tensor at the end of a segment. interior has axes
    N, C, H, W (or N, C) without the padding; border lists, per channel, the
    values of the padding (None if there is none)."""
    if len(labels) == 2 and isinstance(labels[1], tuple):
        order = labels[1][1:]
        value = value.reshape((value.shape[0],) + tuple(sizes[lab] for lab in order))
        labels = (labels[0],) + order
    want = ("N", "C", "H", "W") if len(labels) == 4 else ("N", "C")
    if sorted(map(str, labels)) != sorted(want):
        raise Unsupported(f"cannot tell the channel and pixel axes of a tensor with axes {labels}")
    value = value.transpose([labels.index(lab) for lab in want])
    if len(want) == 2 or not pads:
        return value, None
    (hb, he), (wb, we) = pads.get("H", (0, 0)), pads.get("W", (0, 0))
    h, w = value.shape[2] - hb - he, value.shape[3] - wb - we
    frame = np.ones(value.shape[2:], bool)
    frame[hb:hb + h, wb:wb + w] = False
    return value[:, :, hb:hb + h, wb:wb + w], value[:, :, frame]


# --------------------------------------------------------------------------- analysis


class _Probe:
    """Network values at the end of a segment, as a function of the layer sum s:
    every pixel of output channel f of the layer is set to a[f]*s + b[f]."""

    def __init__(self, graph, seg, shape, a, b, batch, where):
        self.graph, self.seg, self.shape, self.a, self.b = graph, seg, tuple(shape), a, b
        self.batch, self.where = batch, where
        self.labels = ("N", "C", "H", "W") if len(shape) == 3 else ("N", "C")
        self.sizes = dict(zip(self.labels[1:], shape))
        self.end_labels = self.pads = None
        self.border = set()

    def __call__(self, s: np.ndarray) -> np.ndarray:
        y = self.a * s + self.b  # (P, F)
        if self.batch:
            step = self.batch
        else:  # dynamic batch: one run if it fits; never 1, so the batch axis stays recognizable
            step = max(2, min(len(y), PROBE_ELEMENTS // int(np.prod(self.shape))))
        rows = []
        for i in range(0, len(y), step):
            chunk = y[i:i + step]
            n = len(chunk)
            chunk = np.concatenate([chunk, np.repeat(chunk[-1:], step - n, axis=0)])
            probe = chunk.reshape(chunk.shape + (1,) * (len(self.shape) - 1)) * np.ones((1,) + self.shape)
            value, labels, pads = self.graph.run(self.seg, probe, self.labels)
            self.end_labels, self.pads = labels, pads
            interior, border = _split(value, labels, pads, self.sizes)
            per_channel = interior.reshape(step, interior.shape[1], -1).astype(np.float64)
            if np.ptp(per_channel, axis=2).max() > 1e-6 * (1 + np.abs(per_channel).max()):
                raise Unsupported(f"{self.where}: the operators after this layer depend on the pixel position")
            if border is not None:
                self.border.update(np.round(border, 6).ravel().tolist())
            rows.append(per_channel[:n, :, 0])
        return np.concatenate(rows)


def _binary(values: np.ndarray, where: str, warnings: list) -> np.ndarray:
    """values as +-1 (0 becomes +1, as the circuit outputs); _NotBinary otherwise."""
    rounded = np.round(values)
    close = np.abs(values - rounded) <= 1e-4 * np.maximum(1, np.abs(values))
    if not close.all() or not np.isin(rounded, (-1, 0, 1)).all() or ((rounded == 0).sum(axis=0) > 1).any():
        raise _NotBinary
    if (rounded == 0).any():
        warnings.append(f"{where}: the model outputs sign(0) = 0 for some sums; the circuit outputs +1")
    return np.where(rounded >= 0, 1.0, -1.0)


def _steps(probe, s, on, where, warnings) -> tuple[np.ndarray, np.ndarray]:
    """Per output channel, (t, increasing) such that the output is +1 for s >= t
    (increasing) or s <= t, matching `on` at the reachable sums s. Where the
    output switches between two reachable sums, or beyond them, t is where the
    model switches, found by bisection; t = -inf or +inf for constant outputs."""
    def on_at(points):
        try:
            return _binary(probe(points), where, []) > 0
        except _NotBinary:
            raise Unsupported(f"{where}: the activation after this layer is not binary for large sums") from None

    channels = on.shape[1]
    lo, hi = np.zeros(channels), np.zeros(channels)
    increasing, bracketed = np.ones(channels, bool), np.zeros(channels, bool)
    for f in range(channels):
        flips = np.flatnonzero(on[1:, f] != on[:-1, f])
        if len(flips) > 1:
            raise Unsupported(f"{where}: output {f} is not a threshold of the layer sum "
                              f"(it switches {len(flips)} times)")
        if len(flips) == 1:
            i = flips[0]
            lo[f], hi[f], increasing[f], bracketed[f] = s[i], s[i + 1], on[i + 1, f], True
    n = s[-1]
    for j in range(1, 7):  # batch norm can put the threshold beyond the reachable sums
        for side in (-1, 1):
            todo = ~bracketed
            if not todo.any():
                break
            far = side * n * 10.0 ** j
            far_on = on_at(np.full((1, channels), far))[0]
            near_on = on[0] if side < 0 else on[-1]
            new = todo & (far_on != near_on)
            lo[new], hi[new] = (far, -n) if side < 0 else (n, far)
            increasing[new] = near_on[new] if side < 0 else far_on[new]
            bracketed |= new
    for _ in range(200):
        mid = (lo + hi) / 2
        if not ((mid > lo) & (mid < hi))[bracketed].any():
            break
        mid_on = on_at(mid[None, :])[0]
        move_hi = bracketed & (mid_on == increasing)
        hi[move_hi] = mid[move_hi]
        lo[bracketed & ~move_hi] = mid[bracketed & ~move_hi]

    t = np.where(bracketed, (lo + hi) / 2, np.where(on[0], -np.inf, np.inf))
    increasing[~bracketed] = True
    for f in np.flatnonzero(bracketed):
        predicted = s >= t[f] if increasing[f] else s <= t[f]
        flips = np.flatnonzero(on[1:, f] != on[:-1, f])
        if not np.array_equal(predicted, on[:, f]) and len(flips):
            # the model switches exactly at a reachable sum: put t halfway to the next one
            t[f] = (s[flips[0]] + s[flips[0] + 1]) / 2
    return t, increasing


def _affine(s, values) -> tuple[np.ndarray, np.ndarray] | None:
    """(slope, offset) per channel if values = slope*s + offset, else None."""
    basis = np.stack([s, np.ones_like(s)], axis=1)
    coef, *_ = np.linalg.lstsq(basis, values, rcond=None)
    error = np.abs(basis @ coef - values).max(axis=0)
    if (error > 1e-4 * (1 + np.abs(values).max(axis=0))).any():
        return None
    return coef[0], coef[1]


def _thresholds(t, increasing, n) -> tuple[np.ndarray, np.ndarray]:
    """Threshold on the matching fraction m = (s + n) / (2n), as in bnn_to_skill.thresholds()."""
    theta = np.where(np.isfinite(t), (t + n) / (2 * n), np.where(t < 0, -1.0, 2.0))
    return theta, ~increasing


def _binary_weights(w: np.ndarray, where: str) -> tuple[np.ndarray, np.ndarray]:
    """(signs, a) of weights w (outputs, inputs) = signs * a[:, None]."""
    magnitude = np.abs(w)
    a = magnitude.max(axis=1)
    for f in np.flatnonzero(a > 0):
        if not np.allclose(magnitude[f], a[f], rtol=1e-5, atol=0):
            raise Unsupported(f"{where}: the weights of output {f} are not binary (|w| from "
                              f"{magnitude[f].min():.4g} to {a[f]:.4g}); export the model with its weight "
                              "quantizer, so that the weights are +-a")
    return np.where(w >= 0, 1, -1).astype(np.int8), a


def _check_padding(where, pads, node_pads, border, warnings) -> None:
    (hb, he), (wb, we) = pads.get("H", (0, 0)), pads.get("W", (0, 0))
    total = (hb + node_pads[0], he + node_pads[2], wb + node_pads[1], we + node_pads[3])
    if total != (1, 1, 1, 1):
        raise Unsupported(f"{where}: padding (top, bottom, left, right) = {total}; the circuit keeps "
                          "the W x H size and pads each side by one pixel ('same' padding)")
    values = set(border) | ({0.0} if any(node_pads) else set())
    wrong = sorted(v for v in values if abs(v + 1) > 1e-6)
    if wrong:
        warnings.append(
            f"{where}: pads with {', '.join(f'{v:g}' for v in wrong)}, but the circuit pads with VSSA "
            "(activation -1); border pixels will differ from the trained model unless it pads with -1 "
            "(Larq: pad_values=-1.0; PyTorch: F.pad(x, (1, 1, 1, 1), value=-1.0) and Conv2d padding=0)"
        )


def _conv(graph, node, channels, pads, border, warnings) -> Layer:
    where = f"{_name(node)} (Conv)"
    at = _attrs(node)
    w = graph.const(node.input[1], where)
    if w.ndim != 4 or w.shape[2:] != (KERNEL, KERNEL):
        raise Unsupported(f"{where}: kernel {list(w.shape[2:])}; the masks are fixed at 3x3")
    for key, ok in (("strides", [1, 1]), ("dilations", [1, 1])):
        if list(at.get(key, ok)) != ok:
            raise Unsupported(f"{where}: {key} {list(at[key])}; only {ok} is built")
    if at.get("group", 1) != 1:
        raise Unsupported(f"{where}: group {at['group']} is not supported")
    if w.shape[1] != channels:
        raise Unsupported(f"{where}: weights for {w.shape[1]} input channels, but the input has {channels}")
    auto = at.get("auto_pad", "NOTSET")
    node_pads = [1, 1, 1, 1] if auto in ("SAME_UPPER", "SAME_LOWER") else (
        [0, 0, 0, 0] if auto == "VALID" else list(at.get("pads", [0, 0, 0, 0])))
    _check_padding(where, pads, node_pads, border, warnings)

    filters = w.shape[0]
    bias = graph.const(node.input[2], where) if len(node.input) > 2 and node.input[2] else np.zeros(filters)
    signs, a = _binary_weights(w.reshape(filters, -1), where)
    signs = signs.reshape(w.shape).transpose(2, 3, 1, 0)  # (F, C, kh, kw) -> (kh, kw, C, F)
    return Layer("conv", _name(node), signs, a, bias)


def _flatten_order(labels, shape) -> np.ndarray:
    """For each input of a dense layer, its index in Keras flatten order,
    (row*W + column)*C + channel."""
    if not isinstance(labels[1], tuple):
        return np.arange(shape[0])
    channels, height, width = shape
    c, h, w = np.meshgrid(np.arange(channels), np.arange(height), np.arange(width), indexing="ij")
    keras = (h * width + w) * channels + c  # axes C, H, W
    axis = {"C": 0, "H": 1, "W": 2}
    return keras.transpose([axis[lab] for lab in labels[1][1:]]).ravel()


def _dense(graph, node, labels, shape) -> Layer:
    where = f"{_name(node)} ({node.op_type})"
    if len(labels) != 2:
        raise Unsupported(f"{where}: dense layer on a {len(labels)}-D tensor; flatten it first")
    if node.op_type == "MatMul":
        w = graph.const(node.input[1], where)
        bias = np.zeros(w.shape[-1])
    else:
        at = _attrs(node)
        if at.get("transA", 0):
            raise Unsupported(f"{where}: transA is not supported")
        w = graph.const(node.input[1], where)
        w = (w.T if at.get("transB", 0) else w) * at.get("alpha", 1.0)
        c = graph.const(node.input[2], where) if len(node.input) > 2 and node.input[2] else 0.0
        bias = np.broadcast_to(at.get("beta", 1.0) * np.asarray(c, float), (w.shape[1],)).copy()
    order = _flatten_order(labels, shape)
    if w.ndim != 2 or w.shape[0] != len(order):
        raise Unsupported(f"{where}: weights {list(w.shape)} for {len(order)} inputs")
    signs, a = _binary_weights(w.T, where)  # (units, inputs)
    keras = np.empty_like(signs.T)
    keras[order] = signs.T
    return Layer("dense", _name(node), keras, a, bias)


def _analyse(graph: _Graph, model: Model) -> None:
    tensor = graph.input.type.tensor_type
    dims = [d.dim_value if d.HasField("dim_value") else None for d in tensor.shape.dim]
    name = graph.input.name
    if len(dims) != 4:
        raise OnnxError(f"input '{name}' has {len(dims)} axes; expected an image batch, "
                        "(N, C, H, W) or (N, H, W, C)")
    if None in dims[1:]:
        raise OnnxError(f"input '{name}' has shape {dims}; export the model with a fixed image size")
    dtype = onnx.helper.tensor_dtype_to_np_dtype(tensor.elem_type)
    if not np.issubdtype(dtype, np.floating):
        raise OnnxError(f"input '{name}' is {dtype}; BNNtoCMOS needs a floating-point image input")
    batch = dims[0]  # None: any batch size
    full = (batch or 2,) + tuple(dims[1:])

    # Input layout: which axes reach the first Conv as its N, C, H, W.
    seg = graph.segment(name)
    if seg.end is None or seg.end.op_type != "Conv":
        raise Unsupported("no convolution layers found: the network must start with a 3x3 convolution")
    placeholders = ("a0", "a1", "a2", "a3")
    _, labels, _ = graph.run(seg, np.zeros(full, dtype), placeholders, strict=False)
    if sorted(map(str, labels)) != list(placeholders):
        raise Unsupported(f"{_name(seg.end)}: cannot tell the image axes at the first convolution")
    axis_of = dict(zip(labels, "NCHW"))
    in_labels = tuple(axis_of[p] for p in placeholders)
    if in_labels[0] != "N":
        raise Unsupported(f"input '{name}': the first axis is not the batch")
    sizes = dict(zip(in_labels, full))
    model.layout = "".join(in_labels)
    model.height, model.width, model.channels = sizes["H"], sizes["W"], sizes["C"]

    # The circuit takes the binary image directly: whatever runs before the first
    # convolution must leave a +-1 image unchanged.
    border = set()
    for pixel in (-1.0, 1.0):
        value, labels, pads = graph.run(seg, np.full(full, pixel, dtype), in_labels)
        interior, frame = _split(value, labels, pads, sizes)
        if not np.allclose(interior, pixel, atol=1e-4):
            raise Unsupported(f"the operators before the first convolution change a {pixel:+g} pixel into "
                              f"{np.unique(np.round(interior, 4))[:4].tolist()}; the circuit takes the binary "
                              "image (+-1) directly, so export the model with that input")
        if frame is not None:
            border.update(np.round(frame, 6).ravel().tolist())

    node, in_shape = seg.end, (sizes["C"], sizes["H"], sizes["W"])
    seen = set()
    while node is not None:
        seen.add(id(node))
        if node.op_type == "Conv":
            if len(labels) != 4 or labels != ("N", "C", "H", "W"):
                raise Unsupported(f"{_name(node)} (Conv): convolution after a dense layer or a Flatten "
                                  "is not supported")
            layer = _conv(graph, node, in_shape[0], pads, border, model.warnings)
            out_shape = (layer.signs.shape[3],) + in_shape[1:]
            n = KERNEL * KERNEL * in_shape[0]
        else:
            layer = _dense(graph, node, labels, in_shape)
            out_shape = (layer.signs.shape[1],)
            n = layer.signs.shape[0]
        where = f"{layer.name} ({node.op_type})"

        seg = graph.segment(node.output[0])
        probe = _Probe(graph, seg, out_shape, layer.scale, layer.bias, batch, where)
        s = np.arange(-n, n + 1, 2.0)
        values = probe(np.repeat(s[:, None], out_shape[0], axis=1))
        final = seg.end is None or seg.end.op_type in TERMINAL
        affine = _affine(s, values) if final else None
        try:
            on = _binary(values, where, model.warnings) > 0
        except _NotBinary:
            on = None
        if layer.kind == "dense" and affine is not None:
            layer.folded = affine  # classifier output, compared by arg max
        elif on is not None:
            t, increasing = _steps(probe, s, on, where, model.warnings)
            if layer.kind == "conv":
                layer.folded = _thresholds(t, increasing, n)
            else:  # sign(a*s + b) between dense layers
                a = np.where(np.isfinite(t), np.where(increasing, 1.0, -1.0), 0.0)
                b = np.where(np.isfinite(t), -a * t, np.where(t < 0, 1.0, -1.0))
                layer.folded = (a, b)
        elif layer.kind == "conv" and affine is not None:  # the network ends at the batch norm
            slope, offset = affine
            with np.errstate(divide="ignore", invalid="ignore"):
                t = np.where(slope != 0, -offset / slope, np.where(offset >= 0, -np.inf, np.inf))
            layer.folded = _thresholds(t, slope >= 0, n)
        else:
            raise Unsupported(f"{where}: the activation after this layer is not binary (values such as "
                              f"{np.unique(np.round(values, 4))[:4].tolist()}); the circuit passes +-1 "
                              "activations between layers")
        model.layers.append(layer)

        node = seg.end if seg.end is not None and seg.end.op_type in LINEAR else None
        labels, pads, border, in_shape = probe.end_labels, probe.pads, probe.border, out_shape

    missing = [n for n in graph.nodes if n.op_type in LINEAR and n.input and n.input[0] in graph.dynamic
               and id(n) not in seen]
    if missing:
        raise Unsupported(f"{_name(missing[0])} ({missing[0].op_type}): comes after the end of the network "
                          "(a Softmax or ArgMax between layers?)")


def read(path: Path) -> Model:
    try:
        proto = onnx.load(str(path))
    except Exception as e:
        raise OnnxError(f"not an ONNX model ({type(e).__name__}: {e})") from None
    model = Model()
    with np.errstate(all="ignore"):  # probes may evaluate log(0) and the like
        try:
            _analyse(_Graph(proto), model)
        except Unsupported as e:
            model.errors.append(str(e))
    return model
