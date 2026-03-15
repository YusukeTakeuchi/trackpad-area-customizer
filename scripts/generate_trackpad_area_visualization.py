#!/usr/bin/env python3
"""
Generate a trackpad area visualization image from a config JSON.

Usage:
  python3 scripts/generate_trackpad_area_visualization.py \
    --config tmp/sample.json \
    --output tmp/sample-areas.png

Optional:
  --aspect-ratio 1.5965665236   # physical width/height ratio
"""

import argparse
import json
import os
import re
from pathlib import Path

# Make matplotlib/fontconfig cache writable in sandboxed environments.
os.environ.setdefault("MPLCONFIGDIR", "/tmp/mpl")
os.environ.setdefault("XDG_CACHE_HOME", "/tmp")

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import ListedColormap
from matplotlib.patches import Rectangle

DEFAULT_MARGIN = 0.03
# Measured from Apple official top-view image:
# https://help.apple.com/assets/68E55784E266DE1F4A0ACA56/69726E59320F229D6106C907/en_US/56e0abc06f8b1c45f36dd37cef8e4428.png
# trackpad pixel bounds ~= width 372, height 233 -> 372/233 = 1.596...
DEFAULT_TRACKPAD_ASPECT_RATIO = 372.0 / 233.0

NUMBER_RE = r"(?:\d+(?:\.\d+)?|\.\d+)"
PAT_AXIS_CMP_NUM = re.compile(rf"^\s*([xyXY])\s*(<=|<|>=|>)\s*({NUMBER_RE})\s*$")
PAT_NUM_CMP_AXIS = re.compile(rf"^\s*({NUMBER_RE})\s*(<=|<|>=|>)\s*([xyXY])\s*$")
PAT_CHAIN = re.compile(
    rf"^\s*({NUMBER_RE})\s*(<=|<|>=|>)\s*([xyXY])\s*(<=|<|>=|>)\s*({NUMBER_RE})\s*$"
)


def pick_tighter_lower(current, candidate):
    if current is None:
        return candidate
    cur_v, cur_inc = current
    cand_v, cand_inc = candidate
    if cand_v > cur_v:
        return candidate
    if cand_v < cur_v:
        return current
    return (cur_v, cur_inc and cand_inc)


def pick_tighter_upper(current, candidate):
    if current is None:
        return candidate
    cur_v, cur_inc = current
    cand_v, cand_inc = candidate
    if cand_v < cur_v:
        return candidate
    if cand_v > cur_v:
        return current
    return (cur_v, cur_inc and cand_inc)


def parse_bounds(area_expressions):
    bounds = {"x": {"lower": None, "upper": None}, "y": {"lower": None, "upper": None}}
    for expr in area_expressions:
        expr = expr.strip()

        match = PAT_CHAIN.match(expr)
        if match:
            n1, op1, axis, op2, n2 = match.groups()
            axis = axis.lower()
            n1 = float(n1)
            n2 = float(n2)
            if op1 in ("<", "<=") and op2 in ("<", "<="):
                lower = (n1, op1 == "<=")
                upper = (n2, op2 == "<=")
            elif op1 in (">", ">=") and op2 in (">", ">="):
                upper = (n1, op1 == ">=")
                lower = (n2, op2 == ">=")
            else:
                raise ValueError(f"Unsupported chain expression: {expr}")
            bounds[axis]["lower"] = pick_tighter_lower(bounds[axis]["lower"], lower)
            bounds[axis]["upper"] = pick_tighter_upper(bounds[axis]["upper"], upper)
            continue

        match = PAT_AXIS_CMP_NUM.match(expr)
        if match:
            axis, op, raw_n = match.groups()
            axis = axis.lower()
            n = float(raw_n)
            if op == "<":
                bounds[axis]["upper"] = pick_tighter_upper(bounds[axis]["upper"], (n, False))
            elif op == "<=":
                bounds[axis]["upper"] = pick_tighter_upper(bounds[axis]["upper"], (n, True))
            elif op == ">":
                bounds[axis]["lower"] = pick_tighter_lower(bounds[axis]["lower"], (n, False))
            elif op == ">=":
                bounds[axis]["lower"] = pick_tighter_lower(bounds[axis]["lower"], (n, True))
            continue

        match = PAT_NUM_CMP_AXIS.match(expr)
        if match:
            raw_n, op, axis = match.groups()
            axis = axis.lower()
            n = float(raw_n)
            if op == "<":
                bounds[axis]["lower"] = pick_tighter_lower(bounds[axis]["lower"], (n, False))
            elif op == "<=":
                bounds[axis]["lower"] = pick_tighter_lower(bounds[axis]["lower"], (n, True))
            elif op == ">":
                bounds[axis]["upper"] = pick_tighter_upper(bounds[axis]["upper"], (n, False))
            elif op == ">=":
                bounds[axis]["upper"] = pick_tighter_upper(bounds[axis]["upper"], (n, True))
            continue

        raise ValueError(f"Unsupported area expression: {expr}")

    return bounds


def bounds_to_rect(bounds):
    x_lower = bounds["x"]["lower"][0] if bounds["x"]["lower"] is not None else 0.0
    x_upper = bounds["x"]["upper"][0] if bounds["x"]["upper"] is not None else 1.0
    y_lower = bounds["y"]["lower"][0] if bounds["y"]["lower"] is not None else 0.0
    y_upper = bounds["y"]["upper"][0] if bounds["y"]["upper"] is not None else 1.0

    x_lower = max(0.0, min(1.0, x_lower))
    x_upper = max(0.0, min(1.0, x_upper))
    y_lower = max(0.0, min(1.0, y_lower))
    y_upper = max(0.0, min(1.0, y_upper))

    return x_lower, y_lower, max(0.0, x_upper - x_lower), max(0.0, y_upper - y_lower)


def expand_bounds(bounds, margin):
    expanded = {"x": {}, "y": {}}
    for axis in ("x", "y"):
        lower = bounds[axis]["lower"]
        upper = bounds[axis]["upper"]
        expanded[axis]["lower"] = None if lower is None else (max(0.0, lower[0] - margin), lower[1])
        expanded[axis]["upper"] = None if upper is None else (min(1.0, upper[0] + margin), upper[1])
    return expanded


def safe_eval_expr(expr, x, y):
    if not re.fullmatch(r"[0-9xyXY<>=.\s]+", expr):
        raise ValueError(f"Unsafe area expression: {expr}")
    return bool(eval(expr, {"__builtins__": {}}, {"x": x, "y": y, "X": x, "Y": y}))


def rule_matches(rule, x, y):
    return all(safe_eval_expr(expr, x, y) for expr in rule["area"])


def build_first_match_map(rules, width=680, height=680):
    xs = (np.arange(width) + 0.5) / width
    ys = (np.arange(height) + 0.5) / height
    first_match = np.zeros((height, width), dtype=np.int16)
    for row_index, y in enumerate(ys):
        for col_index, x in enumerate(xs):
            matched = 0
            for rule_index, rule in enumerate(rules, start=1):
                if rule_matches(rule, float(x), float(y)):
                    matched = rule_index
                    break
            first_match[row_index, col_index] = matched
    return first_match


def create_figure(rules, output_path, aspect_ratio):
    first_match = build_first_match_map(rules)
    colors = ["#f2f2f2", "#4c78a8", "#f58518", "#54a24b", "#e45756", "#72b7b2", "#b279a2"]
    cmap = ListedColormap(colors[: max(2, len(rules) + 1)])
    x_scale = aspect_ratio

    fig, ax = plt.subplots(figsize=(8.5, 8.2), dpi=220)
    ax.imshow(
        first_match,
        origin="lower",
        extent=[0, x_scale, 0, 1],
        cmap=cmap,
        vmin=0,
        vmax=len(cmap.colors) - 1,
        interpolation="nearest",
        alpha=0.92,
    )
    ax.add_patch(Rectangle((0, 0), x_scale, 1, fill=False, edgecolor="#222", linewidth=2.0))

    legend_lines = []
    for index, rule in enumerate(rules, start=1):
        bounds = parse_bounds(rule["area"])
        x0, y0, width, height = bounds_to_rect(bounds)
        margin = rule.get("missClickMargin", DEFAULT_MARGIN)

        color = colors[index]
        sx0 = x0 * x_scale
        swidth = width * x_scale
        ax.add_patch(Rectangle((sx0, y0), swidth, height, fill=False, edgecolor=color, linewidth=2.0))

        ex0, ey0, ew, eh = bounds_to_rect(expand_bounds(bounds, margin))
        ax.add_patch(
            Rectangle(
                (ex0 * x_scale, ey0),
                ew * x_scale,
                eh,
                fill=False,
                edgecolor=color,
                linewidth=1.2,
                linestyle=(0, (4, 3)),
                alpha=0.95,
            )
        )

        center_x = sx0 + swidth / 2 if width > 0 else sx0
        center_y = y0 + height / 2 if height > 0 else y0
        ax.text(
            center_x,
            center_y,
            f"R{index}: {rule['shortcut']}",
            ha="center",
            va="center",
            fontsize=9,
            color="black",
            bbox={"boxstyle": "round,pad=0.25", "facecolor": "white", "edgecolor": color, "alpha": 0.93},
        )

        margin_note = "default" if "missClickMargin" not in rule else "explicit"
        legend_lines.append(
            f"R{index}  {' && '.join(rule['area'])} -> {rule['shortcut']}  (margin={margin:.2f}, {margin_note})"
        )

    ax.set_xlim(-0.02 * x_scale, 1.02 * x_scale)
    ax.set_ylim(-0.02, 1.02)
    ax.set_aspect("equal")
    tick_positions = np.linspace(0, x_scale, 6)
    tick_labels = [f"{v:.1f}" for v in np.linspace(0, 1, 6)]
    ax.set_xticks(tick_positions)
    ax.set_xticklabels(tick_labels)
    ax.set_yticks(np.linspace(0, 1, 6))
    ax.grid(color="#aaaaaa", alpha=0.2, linewidth=0.6)
    ax.set_xlabel("x (0.0 -> 1.0)")
    ax.set_ylabel("y (0.0 -> 1.0)")
    ax.set_title(
        f"Trackpad Area Visualization (First-match + missClickMargin, W:H={aspect_ratio:.3f}:1)"
    )

    fig.text(0.03, 0.02, "\n".join(legend_lines), fontsize=8.2, family="monospace", va="bottom")
    plt.tight_layout(rect=[0, 0.15, 1, 1])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(output_path)
    plt.close(fig)


def parse_args():
    parser = argparse.ArgumentParser(description="Generate trackpad area visualization from config JSON.")
    parser.add_argument("--config", default="tmp/sample.json", help="Path to config JSON.")
    parser.add_argument("--output", default="tmp/sample-areas.png", help="Path to output PNG.")
    parser.add_argument(
        "--aspect-ratio",
        type=float,
        default=DEFAULT_TRACKPAD_ASPECT_RATIO,
        help="Trackpad physical width/height ratio. Default uses measured MacBook Air ratio.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.aspect_ratio <= 0:
        raise ValueError("--aspect-ratio must be > 0")
    config_path = Path(args.config)
    output_path = Path(args.output)

    rules = json.loads(config_path.read_text())
    create_figure(rules, output_path, args.aspect_ratio)
    print(f"Wrote {output_path.resolve()}")


if __name__ == "__main__":
    main()
