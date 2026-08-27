#!/usr/bin/env python3
"""
Render docs/REPORT.md to REPORT.pdf.

Arial 11 for body text, because the brief asks for it by name. Real Arial is
embedded from C:/Windows/Fonts rather than substituted with a metric clone, so
a font-extraction check reports "Arial" and not "Helvetica".

Two passes. The first records which page each heading lands on; the second
re-renders with those numbers in the table of contents. The table of contents
occupies the same number of pages in both passes, so the numbers it prints stay
correct after it is inserted.

Tables are reflowed to the A4 portrait text width, never clipped: column widths
are proportional to content and every cell wraps. Code blocks shrink to fit
rather than running off the edge.

Usage:  python scripts/build-pdf.py [--md docs/REPORT.md] [--out REPORT.pdf]
"""
import argparse
import os
import re
import sys

from fpdf import FPDF
from fpdf.enums import XPos, YPos

FONTS = {
    ("Arial", ""):  r"C:\Windows\Fonts\arial.ttf",
    ("Arial", "B"): r"C:\Windows\Fonts\arialbd.ttf",
    ("Arial", "I"): r"C:\Windows\Fonts\ariali.ttf",
    ("Arial", "BI"): r"C:\Windows\Fonts\arialbi.ttf",
    ("Mono", ""):   r"C:\Windows\Fonts\consola.ttf",
    ("Mono", "B"):  r"C:\Windows\Fonts\consolab.ttf",
}

BODY_PT = 11
CODE_PT = 8.0
TABLE_PT = 8.5
LEADING = 1.42          # multiple of font size

PAGE_W, PAGE_H = 210.0, 297.0
MARGIN_L = MARGIN_R = 20.0
MARGIN_T = 18.0
MARGIN_B = 18.0
TEXT_W = PAGE_W - MARGIN_L - MARGIN_R

TITLE = "Infrastructure Engineer Assignment"
SUBTITLE = "Infrastructure Engineer | SRE / DevOps \u2014 Broadcasting"
AUTHOR = "Ali Alkhathami"
REPO = "github.com/Alkhathami1/devops-tasks"
DATED = "August 2026"


# --------------------------------------------------------------------------- #
# Markdown parsing: just enough for this document, and explicit about it.
# --------------------------------------------------------------------------- #
def parse(md):
    """Turn markdown into a flat list of blocks."""
    blocks = []
    lines = md.split("\n")
    i = 0
    while i < len(lines):
        ln = lines[i]

        # fenced code
        if ln.startswith("```"):
            lang = ln[3:].strip()
            body = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            blocks.append(("code", {"lang": lang, "lines": body}))
            continue

        # table: a header row followed by a |---| separator
        if ln.lstrip().startswith("|") and i + 1 < len(lines) and re.match(
                r"^\s*\|[\s:|-]+\|\s*$", lines[i + 1]):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                raw = lines[i].strip()
                if not re.match(r"^\|[\s:|-]+\|$", raw):
                    cells = [c.strip() for c in raw.strip("|").split("|")]
                    rows.append(cells)
                i += 1
            if rows:
                blocks.append(("table", rows))
            continue

        # headings
        m = re.match(r"^(#{1,4})\s+(.*)$", ln)
        if m:
            blocks.append(("h", {"level": len(m.group(1)), "text": m.group(2).strip()}))
            i += 1
            continue

        # horizontal rule
        if re.match(r"^\s*(---|\*\*\*|___)\s*$", ln):
            blocks.append(("hr", None))
            i += 1
            continue

        # blockquote
        if ln.lstrip().startswith(">"):
            body = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                body.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            blocks.append(("quote", " ".join(x.strip() for x in body if x.strip())))
            continue

        # list item (bullet or numbered), with continuation lines
        m = re.match(r"^(\s*)([-*+]|\d+\.)\s+(.*)$", ln)
        if m:
            indent = len(m.group(1))
            text = m.group(3)
            i += 1
            while (i < len(lines) and lines[i].strip()
                   and not re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i])
                   and not lines[i].startswith("#")
                   and not lines[i].lstrip().startswith("|")
                   and not lines[i].startswith("```")):
                text += " " + lines[i].strip()
                i += 1
            blocks.append(("li", {"indent": indent, "text": text,
                                  "ordered": bool(re.match(r"\d", m.group(2)))}))
            continue

        # blank
        if not ln.strip():
            i += 1
            continue

        # paragraph
        text = ln.strip()
        i += 1
        while (i < len(lines) and lines[i].strip()
               and not lines[i].startswith("#")
               and not lines[i].startswith("```")
               and not lines[i].lstrip().startswith("|")
               and not lines[i].lstrip().startswith(">")
               and not re.match(r"^\s*([-*+]|\d+\.)\s+", lines[i])
               and not re.match(r"^\s*(---|\*\*\*|___)\s*$", lines[i])):
            text += " " + lines[i].strip()
            i += 1
        blocks.append(("p", text))
    return blocks


CODE_MARK = "\ue000"   # private-use sentinel; never appears in the document


def inline_segments(text, _style=""):
    """Split inline markdown into (text, style, mono) runs.

    Code spans are lifted out before emphasis is considered. A single
    left-to-right scan that treats them as equal alternatives lets an italic
    wrapper pair its opening asterisk with one that lives inside a code span,
    which swallows the span and the rest of the line with it. Removing the
    spans first settles the ambiguity the way a conforming parser does.

    Recurses into emphasis, so a code span inside **bold** is rendered as bold
    monospace rather than printing its own backticks.
    """
    text = LINK_RE.sub(r"\1", text)

    spans = []

    def stash(m):
        spans.append(m.group(1))
        return "%s%d%s" % (CODE_MARK, len(spans) - 1, CODE_MARK)

    text = re.sub(r"`([^`]+)`", stash, text)
    token = re.compile(r"(\*\*\*[^*]+\*\*\*|\*\*.+?\*\*|\*[^*]+\*|_[^_]+_)")
    split_marks = re.compile(CODE_MARK + r"(\d+)" + CODE_MARK)

    def merge(a, b):
        return "".join(sorted(set(a + b), key="BI".index))

    def restore(chunk):
        """Put the spans back so a recursive call re-stashes them."""
        return split_marks.sub(lambda m: "`%s`" % spans[int(m.group(1))], chunk)

    def emit(chunk, style):
        """Turn a plain chunk into runs, reinstating any stashed code span."""
        runs = []
        for i, piece in enumerate(split_marks.split(chunk)):
            if not piece:
                continue
            runs.append((spans[int(piece)] if i % 2 else piece, style, i % 2 == 1))
        return runs

    out = []
    for part in token.split(text):
        if not part:
            continue
        if part.startswith("***") and part.endswith("***"):
            out.extend(inline_segments(restore(part[3:-3]), merge(_style, "BI")))
        elif part.startswith("**") and part.endswith("**"):
            out.extend(inline_segments(restore(part[2:-2]), merge(_style, "B")))
        elif part.startswith("*") and part.endswith("*") and len(part) > 2:
            out.extend(inline_segments(restore(part[1:-1]), merge(_style, "I")))
        elif part.startswith("_") and part.endswith("_") and len(part) > 2:
            out.extend(inline_segments(restore(part[1:-1]), merge(_style, "I")))
        else:
            out.extend(emit(part, _style))
    return out


LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def strip_inline(text):
    """The plain text of a line, markup removed but code-span content intact.

    Defers to inline_segments so it cannot disagree with what gets rendered:
    stripping `[`*_]` blindly would also eat a glob living inside a code span.
    """
    return "".join(run for run, _style, _mono in inline_segments(text))


def preprocess(md):
    """Drop the H1, the status banner, and the hand-written contents list.

    The PDF and the .docx both generate their own contents with real page
    numbers, so the markdown one is redundant; left in, its list items render
    as raw [label](#anchor) markup.
    """
    md = re.sub(r"^#\s+.*?$", "", md, count=1, flags=re.M)
    md = re.sub(r"^##\s+(Contents|Table of contents)\s*$.*?^---\s*$",
                "", md, count=1, flags=re.M | re.S | re.I)
    return md


# --------------------------------------------------------------------------- #
class Report(FPDF):
    def __init__(self, toc_entries=None, toc_pages=1):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.set_margins(MARGIN_L, MARGIN_T, MARGIN_R)
        self.set_auto_page_break(True, margin=MARGIN_B)
        # multi_cell() reserves c_margin on each side internally. Left at the
        # 1mm default, a row height computed from the nominal width under-counts
        # the wrapped lines and the last line is clipped. Zero it and do the
        # padding explicitly.
        self.c_margin = 0
        for (fam, style), path in FONTS.items():
            if not os.path.exists(path):
                sys.exit(f"missing font: {path}")
            self.add_font(fam, style, path)
        self.toc_entries = toc_entries or []
        self.toc_pages = toc_pages
        self.headings = []          # (level, text, page) collected this pass
        self.in_front_matter = True

    # page numbers everywhere except the cover
    def footer(self):
        if self.page_no() == 1:
            return
        self.set_y(-15)
        self.set_font("Arial", "", 9)
        self.set_text_color(110)
        self.cell(0, 8, str(self.page_no() - 1), align="C")
        self.set_text_color(0)

    # ---------------------------------------------------------------- cover
    def cover(self):
        self.add_page()
        self.set_y(88)
        self.set_font("Arial", "B", 26)
        self.multi_cell(TEXT_W, 12, TITLE, align="C")
        self.ln(4)
        self.set_font("Arial", "", 13)
        self.set_text_color(70)
        self.multi_cell(TEXT_W, 8, SUBTITLE, align="C")
        self.set_text_color(0)
        self.ln(14)
        self.set_draw_color(170)
        self.set_line_width(0.4)
        x = MARGIN_L + TEXT_W / 2 - 25
        self.line(x, self.get_y(), x + 50, self.get_y())
        self.ln(14)
        self.set_font("Arial", "", 12)
        self.multi_cell(TEXT_W, 7, AUTHOR, align="C")
        self.ln(2)
        self.set_font("Arial", "", 10)
        self.set_text_color(110)
        # multi_cell leaves the cursor to the RIGHT of the cell by default, so a
        # second call starts past the right margin and renders nothing. Return
        # to the left margin and the next line between them.
        self.multi_cell(TEXT_W, 6, DATED, align="C",
                        new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.multi_cell(TEXT_W, 6, REPO, align="C",
                        new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_text_color(0)

    # ------------------------------------------------------------------ toc
    def render_toc(self):
        start = self.page_no()
        self.add_page()
        self.set_font("Arial", "B", 16)
        self.cell(0, 10, "Contents", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(3)
        for level, text, page in self.toc_entries:
            if level > 3:
                continue
            indent = (level - 2) * 6
            self.set_font("Arial", "B" if level == 2 else "", 10.5 if level == 2 else 10)
            if level == 2:
                self.ln(1.5)
            label = strip_inline(text)
            num = str(page)
            avail = TEXT_W - indent
            self.set_x(MARGIN_L + indent)
            wnum = self.get_string_width(num)
            wlab = self.get_string_width(label)
            # dot leader
            dots_w = avail - wlab - wnum - 3
            if dots_w < 4:
                # very long heading: truncate rather than wrap, keeps one line per entry
                while wlab > avail - wnum - 10 and len(label) > 8:
                    label = label[:-2]
                    wlab = self.get_string_width(label + "\u2026")
                label += "\u2026"
                dots_w = avail - wlab - wnum - 3
            dot = self.get_string_width(".")
            ndots = max(0, int(dots_w / dot)) if dot else 0
            self.set_text_color(0)
            self.cell(wlab + 1, 5.6, label)
            self.set_text_color(150)
            self.cell(dots_w + 1, 5.6, "." * ndots)
            self.set_text_color(0)
            self.cell(wnum + 2, 5.6, num, align="R",
                      new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        used = self.page_no() - start
        return used

    # ------------------------------------------------------------- inline text
    def write_rich(self, text, size=BODY_PT, lh=None, align="J"):
        """Write text honouring **bold**, *italic* and `code` runs, wrapping."""
        lh = lh or size * LEADING / 3.2
        segs = inline_segments(text)
        space_w = None
        for seg_text, style, mono in segs:
            fam = "Mono" if mono else "Arial"
            sz = size - 1.2 if mono else size
            st = "" if mono and style not in ("B", "BI") else style
            if mono and style in ("B", "BI"):
                st = "B"
            self.set_font(fam, st, sz)
            if mono:
                self.set_text_color(25, 25, 25)
            words = re.split(r"(\s+)", seg_text)
            for w in words:
                if w == "":
                    continue
                if w.isspace():
                    self.set_font(fam, st, sz)
                    space_w = self.get_string_width(" ")
                    if self.get_x() + space_w < PAGE_W - MARGIN_R:
                        self.set_x(self.get_x() + space_w)
                    continue
                ww = self.get_string_width(w)
                if self.get_x() + ww > PAGE_W - MARGIN_R:
                    self.ln(lh)
                    self.set_x(MARGIN_L)
                # a single token wider than the column: hard-split it
                if ww > TEXT_W:
                    for ch in w:
                        cw = self.get_string_width(ch)
                        if self.get_x() + cw > PAGE_W - MARGIN_R:
                            self.ln(lh)
                            self.set_x(MARGIN_L)
                        self.cell(cw, lh, ch)
                    continue
                self.cell(ww, lh, w)
            self.set_text_color(0)
        self.ln(lh)

    # ---------------------------------------------------------------- blocks
    def block_heading(self, level, text):
        sizes = {1: 20, 2: 15.5, 3: 12.5, 4: 11.5}
        gap_before = {1: 6, 2: 7, 3: 5, 4: 4}
        size = sizes.get(level, 11)
        label = strip_inline(text)
        if level == 2:
            # start major sections on a fresh page, but never leave a blank one
            if self.get_y() > MARGIN_T + 12:
                self.add_page()
        else:
            need = size * 2.2 + 14
            if self.get_y() + need > PAGE_H - MARGIN_B:
                self.add_page()
            self.ln(gap_before.get(level, 4))
        self.headings.append((level, label, self.page_no() - 1))
        self.set_font("Arial", "B", size)
        self.multi_cell(TEXT_W, size * 0.52, label,
                        new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        if level == 2:
            self.set_draw_color(200)
            self.set_line_width(0.3)
            y = self.get_y() + 1.5
            self.line(MARGIN_L, y, MARGIN_L + TEXT_W, y)
            self.ln(4)
        else:
            self.ln(1.6)

    def block_code(self, lines):
        if not lines:
            return
        size = CODE_PT
        longest = max((len(l) for l in lines), default=0)
        self.set_font("Mono", "", size)
        # Shrink to fit, but only down to a size still worth reading. Below
        # that, wrap: a 400-character JSON log line does not become legible at
        # 4pt, it just stops running off the page.
        MIN_PT = 6.0
        while longest and self.get_string_width("M" * longest) > TEXT_W - 6 and size > MIN_PT:
            size -= 0.25
            self.set_font("Mono", "", size)
        cw = self.get_string_width("M") or 1.0
        cap = max(20, int((TEXT_W - 6) / cw))
        if longest > cap:
            wrapped = []
            for l in lines:
                if len(l) <= cap:
                    wrapped.append(l)
                    continue
                indent = len(l) - len(l.lstrip())
                pad = " " * min(indent + 2, 8)
                wrapped.append(l[:cap])
                rest = l[cap:]
                step = max(10, cap - len(pad))
                while rest:
                    wrapped.append(pad + rest[:step])
                    rest = rest[step:]
            lines = wrapped
        lh = size * 0.48
        pad = 2.0
        height = lh * len(lines) + pad * 2
        if self.get_y() + min(height, 40) > PAGE_H - MARGIN_B:
            self.add_page()
        self.ln(1.5)
        y0 = self.get_y()
        self.set_fill_color(246, 246, 246)
        self.set_draw_color(222)
        drawn = 0
        self.rect(MARGIN_L, y0, TEXT_W, min(height, PAGE_H - MARGIN_B - y0), style="DF")
        self.set_xy(MARGIN_L + pad, y0 + pad)
        for l in lines:
            if self.get_y() + lh > PAGE_H - MARGIN_B:
                self.add_page()
                y0 = self.get_y()
                self.set_fill_color(246, 246, 246)
                self.rect(MARGIN_L, y0, TEXT_W,
                          min(lh * (len(lines) - drawn) + pad * 2,
                              PAGE_H - MARGIN_B - y0), style="DF")
                self.set_xy(MARGIN_L + pad, y0 + pad)
            self.set_font("Mono", "", size)
            self.set_x(MARGIN_L + pad)
            self.cell(TEXT_W - pad * 2, lh, l.replace("\t", "    "),
                      new_x=XPos.LMARGIN, new_y=YPos.NEXT)
            drawn += 1
        self.set_y(self.get_y() + pad)
        self.ln(2)

    def block_table(self, rows):
        if not rows:
            return
        ncols = max(len(r) for r in rows)
        rows = [r + [""] * (ncols - len(r)) for r in rows]
        header, body = rows[0], rows[1:]

        # width proportional to the longest word-run per column, clamped so no
        # column can crowd the others out
        self.set_font("Arial", "", TABLE_PT)
        weights = []
        for c in range(ncols):
            cells = [strip_inline(r[c]) for r in rows]
            longest = max((len(x) for x in cells), default=1)
            typical = sum(len(x) for x in cells) / max(1, len(cells))
            weights.append(max(6.0, min(float(longest), typical * 2.2 + 6)))
        total = sum(weights)
        widths = [max(17.0, TEXT_W * w / total) for w in weights]

        # A column whose content is mostly single unbreakable tokens - file
        # names, identifiers - must be wide enough for its longest token, or
        # the renderer splits "01-direction-a.log" across two lines. Reserve
        # each column its token floor first, then share what is left out in
        # proportion to the original weights.
        floors = []
        for c in range(ncols):
            longest_tok = ""
            for r in rows:
                for tok in strip_inline(r[c]).split():
                    if len(tok) > len(longest_tok):
                        longest_tok = tok
            self.set_font("Arial", "", TABLE_PT)
            floors.append(min(46.0, self.get_string_width(longest_tok) + 3.5))
        if sum(floors) < TEXT_W:
            spare = TEXT_W - sum(floors)
            wsum = sum(weights)
            widths = [floors[c] + spare * weights[c] / wsum for c in range(ncols)]
        scale = TEXT_W / sum(widths)
        widths = [w * scale for w in widths]

        lh = TABLE_PT * 0.46

        def row_height(cells, bold):
            h = 0
            for c, txt in enumerate(cells):
                self.set_font("Arial", "B" if bold else "", TABLE_PT)
                n = self._wrapped_lines(strip_inline(txt), widths[c] - 3)
                h = max(h, n * lh)
            return h + 2.8

        def draw_row(cells, bold, fill):
            h = row_height(cells, bold)
            if self.get_y() + h > PAGE_H - MARGIN_B:
                self.add_page()
                draw_row(header, True, True)
            x = MARGIN_L
            y = self.get_y()
            if fill:
                self.set_fill_color(238, 238, 238)
            else:
                self.set_fill_color(252, 252, 252)
            self.set_draw_color(206)
            self.set_line_width(0.15)
            for c, txt in enumerate(cells):
                self.rect(x, y, widths[c], h, style="DF")
                self.set_xy(x + 1.5, y + 1.1)
                self.set_font("Arial", "B" if bold else "", TABLE_PT)
                self.multi_cell(widths[c] - 3, lh, strip_inline(txt), align="L")
                x += widths[c]
            self.set_xy(MARGIN_L, y + h)

        if self.get_y() + 24 > PAGE_H - MARGIN_B:
            self.add_page()
        self.ln(1.5)
        draw_row(header, True, True)
        for r in body:
            draw_row(r, False, False)
        self.ln(3)

    def _wrapped_lines(self, text, w):
        if w <= 0:
            return 1
        words = text.split()
        if not words:
            return 1
        n, cur = 1, 0.0
        space = self.get_string_width(" ")
        for word in words:
            ww = self.get_string_width(word)
            if cur > 0 and cur + space + ww > w:
                n += 1
                cur = ww
            else:
                cur = cur + (space if cur > 0 else 0) + ww
        return n

    def block_list(self, item):
        bullet = "\u2022  "
        self.set_font("Arial", "", BODY_PT)
        indent = 4 + item["indent"] * 1.2
        lh = BODY_PT * LEADING / 3.2
        if self.get_y() + lh * 2 > PAGE_H - MARGIN_B:
            self.add_page()
        self.set_x(MARGIN_L + indent)
        self.cell(self.get_string_width(bullet) + 0.5, lh, bullet)
        left = self.get_x()
        saved_l, saved_r = self.l_margin, self.r_margin
        self.set_left_margin(left)
        self._write_wrapped_from(item["text"], left, lh)
        self.set_left_margin(saved_l)
        self.ln(0.6)

    def _write_wrapped_from(self, text, left, lh):
        segs = inline_segments(text)
        for seg_text, style, mono in segs:
            fam = "Mono" if mono else "Arial"
            sz = BODY_PT - 1.2 if mono else BODY_PT
            st = "B" if (mono and style in ("B", "BI")) else ("" if mono else style)
            self.set_font(fam, st, sz)
            if mono:
                self.set_text_color(25, 25, 25)
            for w in re.split(r"(\s+)", seg_text):
                if w == "":
                    continue
                if w.isspace():
                    sw = self.get_string_width(" ")
                    if self.get_x() + sw < PAGE_W - MARGIN_R:
                        self.set_x(self.get_x() + sw)
                    continue
                ww = self.get_string_width(w)
                if self.get_x() + ww > PAGE_W - MARGIN_R:
                    self.ln(lh)
                    self.set_x(left)
                self.cell(ww, lh, w)
            self.set_text_color(0)
        self.ln(lh)

    def block_quote(self, text):
        lh = BODY_PT * LEADING / 3.2
        if self.get_y() + lh * 2 > PAGE_H - MARGIN_B:
            self.add_page()
        self.ln(1)
        y0 = self.get_y()
        left = MARGIN_L + 5
        saved = self.l_margin
        self.set_left_margin(left)
        self.set_x(left)
        self.set_text_color(60)
        self._write_wrapped_from(text, left, lh)
        self.set_text_color(0)
        self.set_left_margin(saved)
        self.set_draw_color(160)
        self.set_line_width(0.7)
        self.line(MARGIN_L + 1.5, y0, MARGIN_L + 1.5, self.get_y() - 1)
        self.ln(2)

    def block_hr(self):
        if self.get_y() + 6 > PAGE_H - MARGIN_B:
            return
        self.ln(2)
        self.set_draw_color(215)
        self.set_line_width(0.25)
        self.line(MARGIN_L, self.get_y(), MARGIN_L + TEXT_W, self.get_y())
        self.ln(3)


def render(blocks, toc_entries=None, toc_pages=1):
    pdf = Report(toc_entries=toc_entries, toc_pages=toc_pages)
    pdf.cover()
    if toc_entries:
        used = pdf.render_toc()
        # keep pagination identical between passes
        for _ in range(max(0, toc_pages - used)):
            pdf.add_page()
    else:
        for _ in range(toc_pages):
            pdf.add_page()
        used = toc_pages

    pdf.add_page()
    lh = BODY_PT * LEADING / 3.2
    for kind, payload in blocks:
        if kind == "h":
            pdf.block_heading(payload["level"], payload["text"])
        elif kind == "p":
            pdf.set_font("Arial", "", BODY_PT)
            if pdf.get_y() + lh * 2 > PAGE_H - MARGIN_B:
                pdf.add_page()
            pdf.set_x(MARGIN_L)
            pdf.write_rich(payload, BODY_PT, lh)
            pdf.ln(1.6)
        elif kind == "code":
            pdf.block_code(payload["lines"])
        elif kind == "table":
            pdf.block_table(payload)
        elif kind == "li":
            pdf.block_list(payload)
        elif kind == "quote":
            pdf.block_quote(payload)
        elif kind == "hr":
            pdf.block_hr()
    return pdf, used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--md", default="docs/REPORT.md")
    ap.add_argument("--out", default="REPORT.pdf")
    args = ap.parse_args()

    md = preprocess(open(args.md, encoding="utf-8").read())
    blocks = parse(md)
    # the markdown TOC is replaced by the generated one
    blocks = [b for b in blocks if not (b[0] == "h" and
              strip_inline(b[1]["text"]).lower() in ("table of contents", "contents"))]

    # pass 1: collect heading pages with a provisional TOC length
    guess = 2
    pdf1, used1 = render(blocks, toc_entries=None, toc_pages=guess)
    entries = [(l, t, p) for (l, t, p) in pdf1.headings if l in (2, 3)]

    # size the real TOC, then re-render so its numbers match the final layout
    probe, real_pages = render(blocks[:1], toc_entries=entries, toc_pages=guess)
    pdf2, _ = render(blocks, toc_entries=entries, toc_pages=max(guess, real_pages))
    entries2 = [(l, t, p) for (l, t, p) in pdf2.headings if l in (2, 3)]
    if entries2 != entries:
        pdf2, _ = render(blocks, toc_entries=entries2,
                         toc_pages=max(guess, real_pages))

    pdf2.set_title(TITLE)
    pdf2.set_author(AUTHOR)
    pdf2.set_subject("")
    pdf2.set_keywords("")
    pdf2.set_creator("")
    pdf2.set_producer("")
    pdf2.output(args.out)
    print(f"wrote {args.out}: {pdf2.page_no()} pages, {len(entries2)} TOC entries")


if __name__ == "__main__":
    main()
