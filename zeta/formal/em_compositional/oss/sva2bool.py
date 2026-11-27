#!/usr/bin/env python3
"""Rewrite the concurrent assertions of the compositional demo into the
Boolean form that the yosys-slang frontend accepts.

    python3 sva2bool.py <out_dir> <file.sv>...

yosys-slang takes `assert property (@(posedge clk) disable iff (r) expr)` when
expr is a plain Boolean, but rejects sequence and implication operators. Two
rewrites are applied, both exact for single-clock Boolean operands:

    a |-> b         becomes  !(a) || (b)
    a ##[1:$] b     becomes  <label>_seen && (b), where <label>_seen is a
                    register set by a and cleared by the disable condition
                    (cover statements only)

Labels, clocking and disable conditions are kept. Any other temporal operator
stops the script, so a new property cannot be dropped silently.
"""

import re
import sys
from pathlib import Path

STATEMENT = re.compile(r"\b(\w+)\s*:\s*(assert|assume|cover)\s+property\s*\(")
CLOCK = re.compile(r"\s*@\s*\(\s*posedge\s+(\w+)\s*\)")
DISABLE = re.compile(r"\s*disable\s+iff\s*\(")
TEMPORAL = re.compile(
    r"\|->|\|=>|##|\[\*|\[=|\[->|\b(throughout|within|intersect|"
    r"s_eventually|eventually|always|nexttime|until|s_until|first_match)\b"
)


def closing_paren(text: str, start: int) -> int:
    """Index of the parenthesis that closes the one opened just before start."""
    depth = 1
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unbalanced parentheses")


def split_top(text: str, operator: str) -> list[str]:
    """Split at an operator that is outside every bracket."""
    parts, depth, last, index = [], 0, 0, 0
    while index < len(text):
        if text[index] in "([{":
            depth += 1
        elif text[index] in ")]}":
            depth -= 1
        elif depth == 0 and text.startswith(operator, index):
            parts.append(text[last:index])
            index += len(operator)
            last = index
            continue
        index += 1
    parts.append(text[last:])
    return parts


def rewrite(source: str, name: str) -> tuple[str, int]:
    out, position, count = [], 0, 0
    for match in STATEMENT.finditer(source):
        label, kind = match.group(1), match.group(2)
        end = closing_paren(source, match.end())
        body = source[match.end() : end]
        clock = CLOCK.match(body)
        if not clock:
            sys.exit(f"{name}: {label}: expected an explicit @(posedge clk)")
        rest = body[clock.end() :]
        disable_cond = None
        disable = DISABLE.match(rest)
        if disable:
            close = closing_paren(rest, disable.end())
            disable_cond = rest[disable.end() : close]
            rest = rest[close + 1 :]
        header = body[: len(body) - len(rest)]
        expr = " ".join(rest.split())
        aux = ""
        if "|->" in expr:
            parts = split_top(expr, "|->")
            if len(parts) != 2:
                sys.exit(f"{name}: {label}: nested implication is not supported")
            expr = f"!({parts[0].strip()}) || ({parts[1].strip()})"
        elif "##[1:$]" in expr:
            parts = split_top(expr, "##[1:$]")
            if kind != "cover" or len(parts) != 2:
                sys.exit(f"{name}: {label}: only 'cover a ##[1:$] b' is supported")
            clear = disable_cond if disable_cond is not None else "1'b0"
            aux = (
                f"logic {label}_seen; always_ff @(posedge {clock.group(1)}) "
                f"if ({clear}) {label}_seen <= 1'b0; "
                f"else if ({parts[0].strip()}) {label}_seen <= 1'b1; "
            )
            expr = f"{label}_seen && ({parts[1].strip()})"
        if TEMPORAL.search(expr):
            sys.exit(f"{name}: {label}: unsupported temporal operator in '{expr}'")
        out.append(source[position : match.start()])
        # Keep the statement on its original lines so that reports point there.
        header = " ".join(header.split())
        pad = "\n" * source.count("\n", match.start(), end)
        out.append(f"{aux}{label}: {kind} property ({header} {expr}{pad})")
        position = end + 1
        count += 1
    out.append(source[position:])
    return "".join(out), count


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    for path in map(Path, sys.argv[2:]):
        text, count = rewrite(path.read_text(encoding="utf-8"), path.name)
        (out_dir / path.name).write_text(text, encoding="utf-8")
        print(f"{path}: {count} properties rewritten to {out_dir / path.name}")


if __name__ == "__main__":
    main()
