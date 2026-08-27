#!/usr/bin/env python3
"""
Verify REPORT.pdf against what the brief asks for, by extraction rather than
assertion. Checks:

  1. every font is embedded, and the body face is really Arial
  2. the dominant body size is 11 pt
  3. monospace is used for terminal excerpts
  4. every page carries a page number except the cover
  5. no text crosses the page margins (the tell for a clipped table)
  6. the contents list resolves: every entry points at a page that exists,
     and the page it names actually carries that heading
  7. page count

Exit code is non-zero if any check fails, so the evidence wrapper records a
failure as a failure rather than laundering it into a pass.
"""
import re
import sys

import pymupdf

PDF = sys.argv[1] if len(sys.argv) > 1 else "REPORT.pdf"

PAGE_W, PAGE_H = 595.276, 841.89        # A4 in points
MARGIN_L_PT = 20 / 25.4 * 72
MARGIN_R_PT = PAGE_W - MARGIN_L_PT
MARGIN_T_PT = 18 / 25.4 * 72
MARGIN_B_PT = PAGE_H - 18 / 25.4 * 72
FOOTER_TOP = PAGE_H - 20 / 25.4 * 72   # the band the page number sits in

rc = 0


def ok(msg):
    print(f"[PASS] {msg}")


def bad(msg):
    global rc
    rc = 1
    print(f"[FAIL] {msg}")


doc = pymupdf.open(PDF)
print(f"file       : {PDF}")
print(f"pages      : {doc.page_count}")
print(f"page size  : {doc[0].rect.width:.1f} x {doc[0].rect.height:.1f} pt "
      f"({doc[0].rect.width/72*25.4:.0f} x {doc[0].rect.height/72*25.4:.0f} mm)")
print()

# --------------------------------------------------------------- 1. fonts
print("--- 1. fonts, read out of the PDF ---")
fonts = {}
for page in doc:
    for f in page.get_fonts(full=True):
        xref, ext, ftype, basefont, name, enc = f[:6]
        fonts.setdefault(basefont, {"type": ftype, "ext": ext, "pages": 0})
        fonts[basefont]["pages"] += 1
for bf, meta in sorted(fonts.items()):
    embedded = meta["ext"] not in ("", "n/a")
    print(f"    {bf:28} type={meta['type']:6} embedded={'yes' if embedded else 'NO':3} "
          f"pages={meta['pages']}")

names = " ".join(fonts)
if "Arial" in names:
    ok("Arial is present and embedded (not substituted with a metric clone)")
else:
    bad(f"Arial not found among embedded fonts: {list(fonts)}")

if any(x in names for x in ("Consolas", "Courier", "Mono")):
    ok("a monospace face is embedded for terminal excerpts")
else:
    bad("no monospace face found")

not_embedded = [b for b, m in fonts.items() if m["ext"] in ("", "n/a")]
if not_embedded:
    bad(f"fonts referenced but not embedded: {not_embedded}")
else:
    ok("every font used is embedded in the file")

# ----------------------------------------------------- 2/3. sizes in use
print("\n--- 2. type sizes actually used ---")
sizes = {}
mono_chars = 0
for page in doc:
    for blk in page.get_text("dict")["blocks"]:
        for line in blk.get("lines", []):
            for span in line.get("spans", []):
                key = (round(span["size"], 1), span["font"])
                sizes[key] = sizes.get(key, 0) + len(span["text"])
                if "Consol" in span["font"] or "Cour" in span["font"]:
                    mono_chars += len(span["text"])

body = [(sz, fn, n) for (sz, fn), n in sizes.items()
        if "Arial" in fn and "Bold" not in fn and "Italic" not in fn]
body.sort(key=lambda x: -x[2])
for (sz, fn), n in sorted(sizes.items(), key=lambda x: -x[1])[:10]:
    print(f"    {sz:>5} pt  {fn:22} {n:>7} chars")

if body and abs(body[0][0] - 11.0) < 0.05:
    ok(f"dominant body face is {body[0][1]} at {body[0][0]} pt")
else:
    bad(f"body text is not Arial 11: {body[:1]}")

if mono_chars > 500:
    ok(f"monospace used for {mono_chars} characters of terminal output")
else:
    bad(f"monospace barely used ({mono_chars} chars)")

# ------------------------------------------------------ 4. page numbers
print("\n--- 3. page numbers ---")
missing = []
for i, page in enumerate(doc):
    if i == 0:
        continue
    footer = page.get_text("text", clip=pymupdf.Rect(0, PAGE_H - 60, PAGE_W, PAGE_H))
    if not re.search(r"\b\d+\b", footer):
        missing.append(i + 1)
if missing:
    bad(f"pages with no number in the footer: {missing[:12]}")
else:
    ok(f"every page after the cover carries a number ({doc.page_count - 1} pages)")

# --------------------------------------------------------- 5. overflow
print("\n--- 4. nothing crosses the margins ---")
over = []
for i, page in enumerate(doc):
    for blk in page.get_text("dict")["blocks"]:
        for line in blk.get("lines", []):
            for span in line.get("spans", []):
                if not span["text"].strip():
                    continue
                x0, y0, x1, y1 = span["bbox"]
                # The footer page number lives in the bottom margin on purpose,
                # which is what a footer is. Flagging it made this check report
                # a failure on every page of a correctly laid out document.
                if y0 > FOOTER_TOP and span["text"].strip().isdigit():
                    continue
                if x0 < MARGIN_L_PT - 3 or x1 > MARGIN_R_PT + 3 or y1 > MARGIN_B_PT + 12:
                    over.append((i + 1, round(x0), round(x1), span["text"][:38]))
if over:
    bad(f"{len(over)} span(s) cross a margin; first few:")
    for o in over[:8]:
        print(f"        page {o[0]}  x {o[1]}..{o[2]}  {o[3]!r}")
else:
    ok("no text crosses the left, right or bottom margin")

# -------------------------------------------------------------- 6. TOC
print("\n--- 5. the contents list resolves ---")
toc_text = ""
for i in range(1, min(4, doc.page_count)):
    t = doc[i].get_text("text")
    if "Contents" in t or re.search(r"\.{5,}\s*\d+\s*$", t, re.M):
        toc_text += t
entries = re.findall(r"^(.+?)\.{3,}\s*(\d+)\s*$", toc_text, re.M)
print(f"    contents entries parsed: {len(entries)}")
bad_entries = []
for label, num in entries:
    n = int(num)
    if n < 1 or n > doc.page_count - 1:
        bad_entries.append((label.strip(), n, "page out of range"))
        continue
    page_text = doc[n].get_text("text")          # n is 1-based after the cover
    head = re.sub(r"\s+", " ", label.strip()).strip()
    probe = head[:22]
    if probe and probe.lower() not in re.sub(r"\s+", " ", page_text).lower():
        bad_entries.append((head, n, "heading not found on that page"))
if not entries:
    bad("no contents entries could be parsed")
elif bad_entries:
    bad(f"{len(bad_entries)} contents entr(y/ies) do not resolve:")
    for e in bad_entries[:10]:
        print(f"        {e[1]:>3}  {e[2]:28} {e[0][:46]!r}")
else:
    ok(f"all {len(entries)} contents entries point at the page carrying that heading")

# ------------------------------------------------------- 7. length + metadata
print('\n--- 6. length and metadata ---')
PAGE_CAP = 20
if doc.page_count <= PAGE_CAP:
    ok(f"{doc.page_count} pages, within the {PAGE_CAP}-page limit")
else:
    bad(f"{doc.page_count} pages, over the {PAGE_CAP}-page limit")

md = doc.metadata or {}
for k in ("title", "author"):
    v = (md.get(k) or "").strip()
    print(f"    {k:10}: {v!r}")
    if v:
        ok(f"{k} is set")
    else:
        bad(f"{k} is empty")
extra = {k: v for k, v in md.items()
         if k not in ("title", "author", "format", "creationDate", "modDate",
                      "encryption", "trapped")
         and (v or "").strip()}
if extra:
    bad(f"metadata carries fields beyond title and author: {extra}")
else:
    ok("no metadata beyond title and author")

print()
print("=" * 60)
print("RESULT: PDF VERIFIED" if rc == 0 else "RESULT: FAILURES PRESENT")
print("=" * 60)
sys.exit(rc)
