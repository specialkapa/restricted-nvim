#!/usr/bin/env python3
"""ANSI preview of lua/core/lualine.lua -- run it to see the statusline in colour
before installing. Approximate: real colours are derived at runtime from whatever
Normal / Identifier / Comment / DiagnosticError resolve to in your colorscheme.
Edit PALETTE to match your theme."""

PALETTE = dict(bg="1E1E2E", fg="CDD6F4", grey="45475A", blue="89B4FA",
               teal="94E2D5", green="A6E3A1", mauve="F5C2E7", red="F38BA8",
               bar="313244")

SEP_LEFT, SEP_RIGHT, SEP_COMP = "▌", "▐", "│"

MODES = {"NORMAL": "blue", "INSERT": "green", "VISUAL": "mauve",
         "REPLACE": "red", "COMMAND": "teal", "TERMINAL": "green"}

def _rgb(h): return tuple(int(h[i:i+2], 16) for i in (0, 2, 4))

def seg(text, fg=None, bg=None, bold=False):
    o = "\033[1m" if bold else ""
    if fg: r, g, b = _rgb(PALETTE[fg]); o += f"\033[38;2;{r};{g};{b}m"
    if bg: r, g, b = _rgb(PALETTE[bg]); o += f"\033[48;2;{r};{g};{b}m"
    return o + text + "\033[0m"

def line(mode="NORMAL", width=110, wide=True, branch="feature/ingest",
         file="app/models.py", crumbs="Loader > process", modified=True,
         diff=(3, 1), diag=(2, 1), macro=None):
    L, R, C = SEP_LEFT, SEP_RIGHT, SEP_COMP
    acc = MODES[mode]
    parts, plain = [], 0

    def add(t, **kw):
        nonlocal plain
        parts.append(seg(t, **kw)); plain += len(t)

    add(f" {mode} ", fg="bg", bg=acc, bold=True)
    if L: add(L, fg=acc, bg="bar")
    if branch: add(f" {branch} ", fg="blue", bg="bar")
    if C and branch: add(f" {C}", fg="grey", bg="bar")
    add(f" {file}", fg="fg", bg="bar", bold=True)
    if modified: add(" [+]", fg="mauve", bg="bar")
    if crumbs: add(f" {crumbs} ", fg="grey", bg="bar")

    right, rplain = [], 0
    def radd(t, **kw):
        nonlocal rplain
        right.append(seg(t, **kw)); rplain += len(t)

    if macro: radd(f" recording @{macro} ", fg="red", bg="bar", bold=True)
    if wide and diff:
        radd(f" +{diff[0]} ", fg="green", bg="bar"); radd(f"-{diff[1]} ", fg="red", bg="bar")
    if diag:
        radd(f"E{diag[0]} ", fg="red", bg="bar"); radd(f"W{diag[1]} ", fg="mauve", bg="bar")
    if wide:
        if C: radd(f"{C} ", fg="grey", bg="bar")
        radd("utf-8 ", fg="grey", bg="bar")
        if C: radd(f"{C} ", fg="grey", bg="bar")
        radd("python ", fg="grey", bg="bar")
    if R: radd(R, fg="grey", bg="bar")
    radd(" 12:34 45% ", fg="bg", bg="grey")

    pad = seg(" " * max(1, width - plain - rplain), bg="bar")
    return "".join(parts) + pad + "".join(right)

if __name__ == "__main__":
    print("\n  \033[1mMODES\033[0m\n")
    for m in MODES:
        print(f"  {m:9} " + line(mode=m))
    print("\n  \033[1mNARROW\033[0m / \033[1mMACRO\033[0m / \033[1mBARE\033[0m / \033[1mINACTIVE\033[0m\n")
    print("  " + line(width=70, wide=False, crumbs="process"))
    print("  " + line(width=80, macro="q", crumbs="", branch="main"))
    print("  " + line(branch="", crumbs="", modified=False, diff=None, diag=None))
    print("  " + seg(" app/models.py", fg="grey", bg="bar")
                + seg(" " * 89, bg="bar") + seg("12:34 ", fg="grey", bg="bar"))
    print()
