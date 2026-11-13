#!/usr/bin/env python3
"""Markdown (with mermaid) -> styled PDF: mermaid-cli for diagrams, pandoc -> HTML, Chrome headless -> PDF.

Usage:
    python3 scripts/build_pdf.py article/ARTICLE-UK.md article/ARTICLE.md [more .md files ...]
Writes PDF next to each source file.
Needs: pandoc, npx (node), Google Chrome at /Applications/Google Chrome.app.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

CSS = """
@page { size: A4; margin: 22mm 18mm; }
body { font-family: 'Helvetica Neue', Arial, sans-serif; font-size: 10.5pt; line-height: 1.55; color: #1a1a2e; }
h1 { font-size: 21pt; line-height: 1.25; margin: 0 0 6pt; color: #12233d; }
h2 { font-size: 14.5pt; margin: 22pt 0 8pt; border-bottom: 2px solid #e8eaf0; padding-bottom: 4pt; color: #12233d; }
h3 { font-size: 12pt; margin: 14pt 0 6pt; }
p { margin: 6pt 0; }
strong { color: #0d1b2e; }
code { font-family: Menlo, monospace; font-size: 8.8pt; background: #f2f4f8; padding: 1px 4px; border-radius: 3px; }
pre { background: #f7f8fb; border: 1px solid #e3e6ee; border-radius: 6px; padding: 10pt 12pt; overflow-x: hidden; page-break-inside: avoid; }
pre code { background: none; font-size: 8.3pt; line-height: 1.45; }
table { border-collapse: collapse; width: 100%; margin: 10pt 0; font-size: 9.5pt; page-break-inside: avoid; }
th { background: #eef1f6; text-align: left; padding: 5pt 8pt; border: 1px solid #d8dce6; }
td { padding: 5pt 8pt; border: 1px solid #d8dce6; vertical-align: top; }
img { max-width: 100%; }
figure { margin: 12pt 0; text-align: center; page-break-inside: avoid; }
a { color: #1857c2; text-decoration: none; }
ul, ol { margin: 6pt 0; padding-left: 20pt; }
li { margin: 3pt 0; }
"""


def run(cmd, ok_codes=(0,)):
    """Run a command; Chrome exits non-zero even on success, so callers pass ok_codes."""
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.returncode in ok_codes, r


def build(src_md: str) -> str:
    work = tempfile.mkdtemp(prefix="pdfbuild-")
    text = open(src_md, encoding="utf-8").read()

    # Strip internal HTML comments (draft checklists) and the article-file header line.
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"^# (ARTICLE[^#\n]*?)\(.*?\)\n", "", text, count=1)

    # Render every mermaid block to SVG and reference it as an image.
    blocks = re.findall(r"```mermaid\n(.*?)```", text, flags=re.S)
    for i, block in enumerate(blocks):
        mmd = os.path.join(work, f"m{i}.mmd")
        svg = os.path.join(work, f"m{i}.svg")
        open(mmd, "w").write(block)
        ok, r = run(f"npx -y @mermaid-js/mermaid-cli -i {mmd} -o {svg}")
        if not ok or not os.path.exists(svg):
            sys.exit(f"mermaid render failed for block {i}:\n{r.stderr[-800:]}")
        text = text.replace("```mermaid\n" + block + "```", f"![]({svg})")

    conv = os.path.join(work, "conv.md")
    open(conv, "w").write(text)
    css = os.path.join(work, "style.css")
    open(css, "w").write(CSS)
    html = os.path.join(work, "out.html")
    title = os.path.basename(src_md)
    ok, r = run(
        f'pandoc "{conv}" -f markdown -t html5 -s -c style.css '
        f'--metadata pagetitle="{title}" -o "{html}" --embed-resources'
    )
    if not ok:
        sys.exit(f"pandoc failed:\n{r.stderr[-800:]}")

    out_pdf = os.path.splitext(src_md)[0] + ".pdf"
    profile = os.path.join(work, "chrome-" + uuid.uuid4().hex[:8])
    # Chrome headless may exit non-zero even when the PDF is written; verify by size.
    run(
        f'"{CHROME}" --headless --disable-gpu --no-first-run --user-data-dir="{profile}" '
        f'--print-to-pdf="{out_pdf}" --no-pdf-header-footer --virtual-time-budget=15000 '
        f'"file://{html}"',
        ok_codes=(0, 1, 2, 42),
    )
    if os.path.exists(out_pdf) and os.path.getsize(out_pdf) > 10000:
        print("built", out_pdf, os.path.getsize(out_pdf), "bytes")
        shutil.rmtree(work, ignore_errors=True)
        return out_pdf
    sys.exit(f"no PDF produced for {src_md}:\n{r.stdout[-400:]}{r.stderr[-400:]}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: build_pdf.py FILE.md [FILE.md ...]")
    for f in sys.argv[1:]:
        build(f)
