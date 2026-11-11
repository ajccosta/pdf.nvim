# render.py: renders PDF pages and edits their comments for pdf.nvim, one JSON
# request per line on stdin, one JSON reply per line on stdout. Kept running,
# so documents stay open and a page drawn once is cut from for each scroll
# step. A request's "op" picks what it does (render when there is none); the
# reply carries its "id", or {"id", "error"}.
#
# render: {"file", "page" (0-based), "width", "height" (in pixels), "out"},
# then either
#   {"zoom", "x", "y"}: what a window that size shows. zoom 1 fits the whole
#     page in it, "width" fits its width; at more, it shows the page from
#     (x, y), in points from its top left corner;
#   {"scale", "px", "py"}: the part drawn at scale (pixels per point) from
#     (px, py), in pixels.
# With "continuous": true, the document's pages are stacked, "gap" pixels
# apart in "bg" ("#rrggbb"), at the page's scale, and the view goes on into
# the pages around it; py is then from the first page's top. Either way it
# writes a PNG at out, at most width x height. With "select" {"page", "a",
# "b"} ({"x", "y"} on that page, in points; "lines": true for whole lines),
# the text from a to b shows selected, and the reply's "selected" has it;
# else with "cursor" {"page", "x", "y"}, the character there shows as a
# block. With "links": {"cols": the
# text's width, "row": a row's height in pixels, "sides": ["left", "right"] or
# one}, each comment goes on the side where its text sits nearest its row, a
# line from it to that edge of the page.
#
# The reply: {"id", "count" (pages), "page" (the one at the view's top), "iw",
# "ih" (the image's size), "x", "y" (where in page the view starts, kept in
# the document), "mx", "my" (the most they can be), "vw", "vh" (the window's
# size), "pw", "ph" (page's size), all in points, "zoom", "scale", "px", "py",
# "pxw", "pxh" (all that can show, in pixels), "tops" (continuous, at a zoom:
# each page's top in pixels), "pages" (those the image shows, each {"page",
# "top", "marks"}), "notes" (comments on page), "marks" (page's), "commented"
# (whether any page has one)}. Marks are a page's comments, top to bottom,
# each {"id", "y": just under it, in points, "side": where its text goes,
# "content", "color": "#rrggbb"}.
#
# comments: {"file"}: {"comments": the document's comments, each {"id", "page",
# "type", "content", "rect" (in points)}}.
#
# at: {"file", "page", "x", "y"}: {"comment": the one there, as comments has
# it, or null}.
#
# move: {"file", "page", "x", "y", "motion", ...}: where a text cursor goes;
# see move.
#
# apply: {"file", "changes"}, each {"do": "add", "page", "x", "y", "content",
# "color": "#rrggbb" (optional)} (with "select" as render takes it, a
# highlight of that text, else a note),
# {"do": "set", "id", "content"} or {"do": "delete", "id"}: saves them into
# the PDF, with what other readers need to open each comment (see tidy),
# then replies as comments does, with "added": the new ones' ids.
import getpass
import json
import os
import re
import sys
import uuid

import fitz

docs = {}  # by file: (mtime, document)
pages = {}  # (file, mtime, page, links, scale): the whole page drawn
sheets = {}  # (file, mtime, page): the page with its links, to draw
texts = {}  # (file, mtime, page): its Text
MAX_PAGES = 6
MAX_PIXELS = 40_000_000  # past this, only the part asked for is drawn


def document(file):
    mtime = os.stat(file).st_mtime
    if file not in docs or docs[file][0] != mtime:
        docs[file] = (mtime, fitz.open(file))
    return docs[file]


def cached(cache, key, make):
    if key not in cache:
        while len(cache) >= MAX_PAGES:
            cache.pop(next(iter(cache)))
        cache[key] = make()
    return cache[key]


def whole_page(file, mtime, p, links, sheet, scale):
    return cached(pages, (file, mtime, p.number, links, round(scale, 6)),
                  lambda: sheet.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False))


class Text:
    """A page's characters in reading order, each its rect as shown, its rect
    on the unrotated page, its char and its line's number; and each line's
    first and past-last character, and block (paragraph)."""

    def __init__(self, p):
        self.chars, self.lines, self.blocks = [], [], []
        for b in p.get_text("rawdict")["blocks"]:
            for l in b.get("lines", []):
                first = len(self.chars)
                for s in l["spans"]:
                    for c in s["chars"]:
                        raw = fitz.Rect(c["bbox"])
                        self.chars.append((raw * p.rotation_matrix, raw, c["c"], len(self.lines)))
                if len(self.chars) > first:
                    self.lines.append((first, len(self.chars)))
                    self.blocks.append(b["number"])

    def nearest(self, pt):
        """The character at pt (a {"x", "y"}), else the one nearest it."""
        pt = fitz.Point(pt["x"], pt["y"])
        return min(range(len(self.chars)),
                   key=lambda i: 0 if pt in self.chars[i][0] else pt.distance_to(self.chars[i][0]))


def page_text(file, mtime, p):
    return cached(texts, (file, mtime, p.number), lambda: Text(p))


def selection(file, mtime, p, sel):
    """The text from sel's a to its b (with "lines", from the start of a's
    line to the end of b's): its text, and a rect per line both as shown and
    on the unrotated page (for a highlight's quads)."""
    t = page_text(file, mtime, p)
    if not t.chars:
        return "", [], []
    i, j = sorted((t.nearest(sel["a"]), t.nearest(sel["b"])))
    if sel.get("lines"):
        i, j = t.lines[t.chars[i][3]][0], t.lines[t.chars[j][3]][1] - 1
    lines = {}
    for shown, raw, _, line in t.chars[i:j + 1]:
        if line in lines:
            lines[line] = (lines[line][0] | shown, lines[line][1] | raw)
        else:
            lines[line] = (shown, raw)
    text = ""
    for a, b in ((max(i, t.lines[n][0]), min(j + 1, t.lines[n][1])) for n in lines):
        part = "".join(c[2] for c in t.chars[a:b]).strip()
        # a word broken over two lines ("sys-" "tems") whole again
        if text.endswith("-") and text[-2:-1].isalpha() and part[:1].islower():
            text = text[:-1] + part
        else:
            text = (text + " " + part).strip()
    return text, [v[0] for v in lines.values()], [v[1] for v in lines.values()]


def kind(c):
    """A character's class, as Vim's words have them: 0 blank, 1 a word's
    letters, 2 punctuation."""
    return 0 if c.isspace() or not c else 1 if c.isalnum() or c == "_" else 2


def move(r):
    """Where the cursor at ("page", "x", "y") goes by "motion" ("count"
    times), as Vim moves it over text: h l j k w b e 0 ^ $ { } gg G, f F t T
    (to "char" on the line; "again" for ; and , past a t's char next to it),
    or here (the character there). j and k keep to the column "want"; "stay" keeps it
    on its page. Reply: {"page", "x", "y" (the character's middle), "want",
    "x0", "y0", "x1", "y1" (its box)}, all in points; or {"page": null} when
    the document has no text."""
    mtime, doc = document(r["file"])
    stay = r.get("stay")
    text = lambda n: page_text(r["file"], mtime, doc[n])

    def with_text(n, d):
        """The nearest page from n on, in direction d, with text."""
        while 0 <= n < doc.page_count:
            if text(n).chars:
                return n
            if stay:
                return None
            n += d
        return None

    def step(pos, d):
        n, i = pos
        if 0 <= i + d < len(text(n).chars):
            return n, i + d
        if stay:
            return None
        m = with_text(n + d, d)
        return m is not None and (m, 0 if d > 0 else len(text(m).chars) - 1) or None

    def kind_at(pos):
        return kind(text(pos[0]).chars[pos[1]][2])

    def line(pos):
        return pos[0], text(pos[0]).chars[pos[1]][3]

    def word_start(pos):
        prev, p = kind_at(pos), pos
        while q := step(p, 1):
            k = kind_at(q)
            if line(q) != line(p):
                prev = 0
            if k and k != prev:
                return q
            prev, p = k, q
        return p

    def word_edge(pos, d):
        """e (d 1) or b (d -1): the next end, or the last start, of a word."""
        p, last = step(pos, d), pos
        while p:
            k, q = kind_at(p), step(p, d)
            if k and (not q or line(q) != line(p) or kind_at(q) != k):
                return p
            last, p = p, q
        return last

    def in_line(pos, which):
        n, i = pos
        t = text(n)
        a, b = t.lines[t.chars[i][3]]
        if which == "0":
            return n, a
        if which == "$":
            return n, b - 1
        return n, next((k for k in range(a, b) if kind(t.chars[k][2])), a)

    def find(pos, motion, ch):
        """f F t T: the next ch on the line, or the character before it."""
        n, i = pos
        t = text(n)
        a, b = t.lines[t.chars[i][3]]
        d = 1 if motion in ("f", "t") else -1
        till = motion in ("t", "T")
        k = i + d * (2 if till and r.get("again") else 1)
        while a <= k < b:
            if t.chars[k][2] == ch:
                return n, k - d if till else k
            k += d
        return pos

    def to_line(pos, d, want):
        n, i = pos
        t = text(n)
        k = t.chars[i][3] + d
        if not 0 <= k < len(t.lines):
            m = None if stay else with_text(n + d, d)
            if m is None:
                return pos
            n, t = m, text(m)
            k = 0 if d > 0 else len(t.lines) - 1
        a, b = t.lines[k]
        return n, min(range(a, b), key=lambda j: abs((t.chars[j][0].x0 + t.chars[j][0].x1) / 2 - want))

    def block_start(t, k):
        return next(j for j in range(k, -1, -1) if j == 0 or t.blocks[j - 1] != t.blocks[k])

    def paragraph(pos, d):
        """} (d 1) or { (d -1): the next paragraph's start, or this one's
        (the last one's when on it)."""
        n, i = pos
        t = text(n)
        k = t.chars[i][3]
        if d < 0 and t.lines[block_start(t, k)][0] < i:
            return n, t.lines[block_start(t, k)][0]
        if d > 0:
            to = next((j for j in range(k + 1, len(t.lines)) if t.blocks[j] != t.blocks[k]), None)
        else:
            s0 = block_start(t, k)
            to = block_start(t, s0 - 1) if s0 > 0 else None
        if to is not None:
            return n, t.lines[to][0]
        m = None if stay else with_text(n + d, d)
        if m is None:
            return pos
        tm = text(m)
        return m, tm.lines[0 if d > 0 else block_start(tm, len(tm.lines) - 1)][0]

    motion, count = r["motion"], int(r.get("count") or 0)
    n = with_text(int(r["page"]), 1)
    if n is None:
        n = with_text(int(r["page"]), -1)
    if n is None:
        return dict(page=None)
    pos = (n, text(n).nearest(r) if n == int(r["page"]) else 0)
    want = r.get("want")
    if motion in ("gg", "G"):
        if count:
            m = with_text(min(count, doc.page_count) - 1, 1)
            pos = (m, 0) if m is not None else pos
        else:
            d = 1 if motion == "gg" else -1
            m = with_text(0 if d > 0 else doc.page_count - 1, d)
            pos = (m, 0 if d > 0 else text(m).lines[-1][0])
    elif motion != "here":
        for _ in range(max(1, count)):
            if motion in ("h", "l"):
                q = step(pos, -1 if motion == "h" else 1)
                pos = q if q and line(q) == line(pos) else pos
            elif motion in ("j", "k"):
                if want is None:
                    rc = text(pos[0]).chars[pos[1]][0]
                    want = (rc.x0 + rc.x1) / 2
                pos = to_line(pos, 1 if motion == "j" else -1, want)
            elif motion == "w":
                pos = word_start(pos)
            elif motion in ("e", "b"):
                pos = word_edge(pos, 1 if motion == "e" else -1)
            elif motion in ("0", "^", "$"):
                pos = in_line(pos, motion)
            elif motion in ("{", "}"):
                pos = paragraph(pos, -1 if motion == "{" else 1)
            elif motion in ("f", "F", "t", "T"):
                q = find(pos, motion, r["char"])
                if q == pos:
                    break
                pos = q
    rc = text(pos[0]).chars[pos[1]][0]
    if motion not in ("j", "k"):
        want = None
    return dict(page=pos[0], x=(rc.x0 + rc.x1) / 2, y=(rc.y0 + rc.y1) / 2, want=want,
                x0=rc.x0, y0=rc.y0, x1=rc.x1, y1=rc.y1)


HIGHLIGHTS = (fitz.PDF_ANNOT_HIGHLIGHT, fitz.PDF_ANNOT_UNDERLINE, fitz.PDF_ANNOT_STRIKE_OUT, fitz.PDF_ANNOT_SQUIGGLY)


def marks(p, links=None, scale=1):
    """p's comments, top to bottom: each (annot, its first line's box, its
    colour, the side its text goes on). The sides are links' sides, each
    comment on the one where its text, about its lines' rows tall, starts
    nearest its row; on a tie, the side of the page it is nearer. Its line
    runs just under its text, not through the words beside it."""
    found = []
    for a in p.annots():
        if not is_comment(a):
            continue
        v = a.vertices
        if a.type[0] in HIGHLIGHTS and v and len(v) % 4 == 0:
            first = fitz.Quad(v[:4]).rect * p.rotation_matrix
        else:
            first = a.rect * p.rotation_matrix
        found.append((a, first, a.colors.get("stroke") or (1, 0.85, 0)))
    found.sort(key=lambda f: (f[1].y0, f[1].x0))
    sides = links["sides"] if links else ["right"]
    row, width = (links["row"] / scale, max(1, links["cols"] - 2)) if links else (0, 1)
    below = {side: 0 for side in sides}
    out = []
    for a, first, color in found:
        y = first.y1 + 1
        lines = sum(-(-len(l.strip()) // width) for l in a.info.get("content", "").split("\n") if l.strip())
        near = "left" if first.x0 + first.x1 < p.rect.width else "right"
        side = min(sides, key=lambda s: (max(y, below[s]), s != near))
        below[side] = max(y, below[side]) + (max(lines, 1) + 1) * row
        out.append((a, first, color, side))
    return out


def has_comments(file, mtime, doc):
    return cached(sheets, (file, mtime, "any"), lambda: any(is_comment(a) for p in doc for a in p.annots()))


def sheet(file, mtime, p, found):
    """p with a line from each of its comments to its text's side."""
    if not found:
        return p

    def make():
        pw, ph = p.rect.width, p.rect.height
        one = fitz.open()
        one.insert_pdf(p.parent, from_page=p.number, to_page=p.number)
        one.bake()  # its comments into its content, to show with it
        out = fitz.open()
        s = out.new_page(width=pw, height=ph)
        s.show_pdf_page(s.rect, one, 0)
        for _, first, color, side in found:
            y = first.y1 + 1
            at, edge = (first.x0, 0) if side == "left" else (first.x1, pw)
            dark = tuple(c * 0.75 for c in color)
            s.draw_line(fitz.Point(at, y), fitz.Point(edge, y), color=dark, width=0.6, dashes="[2 1.5] 0")
        return out, s  # out kept alive with s

    return cached(sheets, (file, mtime, p.number, sides_of(found)), make)[1]


def sides_of(found):
    return "".join(f[3][0] for f in found)


def sizes(file, mtime, doc):
    """Each page's rect, in points."""
    return cached(sheets, (file, mtime, "sizes"), lambda: [q.rect for q in doc])


def piece(r, mtime, p, scale, links, rect):
    """The part rect (in p's pixels at scale) of p drawn, with its comments'
    links, origin at rect's corner; and p's marks."""
    found = marks(p, links, scale)
    src = sheet(r["file"], mtime, p, found) if links else p
    if p.rect.width * p.rect.height * scale * scale <= MAX_PIXELS:
        page = whole_page(r["file"], mtime, p, links and sides_of(found), src, scale)
        pix = fitz.Pixmap(fitz.csRGB, rect & page.irect, False)
        pix.copy(page, pix.irect)
    else:
        pix = src.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=fitz.Rect(rect) / scale, alpha=False)
    return pix, found


def render(r):
    mtime, doc = document(r["file"])
    p = doc[max(0, min(int(r["page"]), doc.page_count - 1))]
    width, height = int(r["width"]), int(r["height"])
    pw, ph = p.rect.width, p.rect.height
    if "scale" in r:
        scale = float(r["scale"])
        zoom = scale / min(width / pw, height / ph)
    else:
        fit = min(width / pw, height / ph)
        zoom = max(1, width / pw / fit) if r["zoom"] == "width" else float(r["zoom"])
        scale = fit * zoom
    links = r.get("links")
    m = fitz.Matrix(scale, scale)
    # the pages it may show, stacked gap pixels apart: py and the tops are
    # from the first one's top
    continuous = bool(r.get("continuous"))
    shown = range(doc.page_count) if continuous else [p.number]
    rects = sizes(r["file"], mtime, doc)
    tops, top = {}, 0
    for n in shown:
        tops[n] = top
        top += (rects[n] * m).irect.height + int(r.get("gap", 0))
    pxh = top - int(r.get("gap", 0))
    pxw = max((rects[n] * m).irect.width for n in shown)
    w, h = min(pxw, width), min(pxh, height)
    if "scale" in r:
        px, py = int(r["px"]), int(r["py"])
    else:
        px, py = round(float(r["x"]) * scale), tops[p.number] + round(float(r["y"]) * scale)
    px, py = max(0, min(px, pxw - w)), max(0, min(py, pxh - h))
    # filled from bytes: set_rect fills pixel by pixel in Python, seconds a view
    bg = r.get("bg", "#000000")
    pix = fitz.Pixmap(fitz.csRGB, w, h, bytes.fromhex(bg[1:]) * (w * h), False)
    reply, pages = {}, []
    sel = r.get("select")
    for n in shown:
        if tops[n] >= py + h or tops[n] + (rects[n] * m).irect.height <= py:
            continue
        q = doc[n]
        part, found = piece(r, mtime, q, scale, links, fitz.IRect(px, py - tops[n], px + w, py - tops[n] + h))
        if sel and sel.get("page", n) == n:
            text, boxes, _ = selection(r["file"], mtime, q, sel)
            for rc in boxes:
                box = (rc * scale).irect & part.irect
                if not box.is_empty:
                    part.invert_irect(box)
            reply["selected"] = text
        cur = r.get("cursor")
        if cur and not sel and cur.get("page") == n and page_text(r["file"], mtime, q).chars:
            # the cursor: its character drawn as Vim's block over it
            t = page_text(r["file"], mtime, q)
            box = (t.chars[t.nearest(cur)][0] * scale).irect & part.irect
            if not box.is_empty:
                part.invert_irect(box)
        part.set_origin(part.x - px, part.y + tops[n] - py)
        pix.copy(part, part.irect)
        pages.append(dict(page=n, top=tops[n], marks=[
            dict(id=a.xref, y=first.y1 + 1, side=side, content=a.info.get("content", ""),
                 color="#%02x%02x%02x" % tuple(round(c * 255) for c in color))
            for a, first, color, side in found]))
    pix.save(r["out"])
    # the page at the view's top, and where in it
    at = max((n for n in shown if tops[n] <= py), key=lambda n: tops[n])
    reply["tops"] = [tops[n] for n in shown] if continuous and "scale" not in r else None
    top = next((g for g in pages if g["page"] == at), dict(marks=[]))
    return dict(reply, page=at, pages=pages, notes=len(top["marks"]), marks=top["marks"],
                commented=has_comments(r["file"], mtime, doc), count=doc.page_count, iw=pix.width, ih=pix.height,
                x=px / scale, y=(py - tops[at]) / scale, mx=(pxw - w) / scale, my=(pxh - h - tops[at]) / scale,
                vw=w / scale, vh=h / scale, pw=rects[at].width, ph=rects[at].height,
                zoom=zoom, scale=scale, px=px, py=py, pxw=pxw, pxh=pxh)


def is_comment(a):
    return a.type[0] in (fitz.PDF_ANNOT_TEXT, fitz.PDF_ANNOT_FREE_TEXT) or bool(a.info.get("content"))


def describe(p, a):
    return dict(id=a.xref, page=p.number, type=a.type[1], content=a.info.get("content", ""),
                rect=list(a.rect * p.rotation_matrix))


def comments(r):
    _, doc = document(r["file"])
    return dict(comments=[describe(p, a) for p in doc for a in p.annots() if is_comment(a)])


def covers(p, a, pt):
    """Whether a shows at pt: on a highlight's text, not just its box."""
    v = a.vertices
    if a.type[0] == fitz.PDF_ANNOT_HIGHLIGHT and v and len(v) % 4 == 0:
        return any(pt in fitz.Quad(v[i:i + 4]).rect * p.rotation_matrix for i in range(0, len(v), 4))
    return pt in a.rect * p.rotation_matrix


def at(r):
    mtime, doc = document(r["file"])
    p = doc[int(r["page"])]
    pt = fitz.Point(float(r["x"]), float(r["y"]))
    hits = [a for a in p.annots() if is_comment(a) and covers(p, a, pt)]
    t = page_text(r["file"], mtime, p)
    if not hits and t.chars:
        # beside a character, in the gap between lines: on it
        c = t.chars[t.nearest(r)][0]
        if pt.distance_to(c) < (c.y1 - c.y0) / 2:
            mid = fitz.Point((c.x0 + c.x1) / 2, (c.y0 + c.y1) / 2)
            hits = [a for a in p.annots() if is_comment(a) and covers(p, a, mid)]
    return dict(comment=describe(p, hits[-1]) if hits else None)


def find(doc, xref):
    for p in doc:
        for a in p.annots():
            if a.xref == xref:
                return p, a
    raise KeyError(f"no comment #{xref}")


def change(doc, changes):
    """Make changes; the ids of the comments added."""
    file = doc.name
    added = []
    for c in changes:
        if c["do"] == "add":
            p = doc[int(c["page"])]
            quads = c.get("select") and selection(file, os.stat(file).st_mtime, p, c["select"])[2]
            if quads:
                a = p.add_highlight_annot(quads)
            else:
                # x, y are where it shows; the note's point is on the unrotated page
                # (kept on the page)
                x = max(0, min(float(c["x"]), p.rect.width - 20))
                y = max(0, min(float(c["y"]), p.rect.height - 20))
                at = fitz.Point(x, y) * p.derotation_matrix
                a = p.add_text_annot(at, c["content"], icon="Comment")
                a.set_popup(beside(p, a))
            a.set_info(content=c["content"], title=getpass.getuser())
            if c.get("color"):
                a.set_colors(stroke=[int(c["color"][i:i + 2], 16) / 255 for i in (1, 3, 5)])
            a.update()
            # its own name: PyMuPDF's start again with each opening
            doc.xref_set_key(a.xref, "NM", fitz.get_pdf_str(str(uuid.uuid4())))
            added.append(a.xref)
        elif c["do"] == "set":
            _, a = find(doc, int(c["id"]))
            a.set_info(content=c["content"])
            a.update()
            doc.xref_set_key(a.xref, "M", fitz.get_pdf_str(fitz.get_pdf_now()))
        elif c["do"] == "delete":
            p, a = find(doc, int(c["id"]))
            p.delete_annot(a)
    return added


def refs(doc, xref, key):
    """The objects an array key of xref points to."""
    t, v = doc.xref_get_key(xref, key)
    if t == "xref":
        v = doc.xref_object(int(v.split()[0]))
    return [int(x) for x in re.findall(r"(\d+) 0 R", v)] if t in ("array", "xref") else []


def beside(p, a):
    """Where a's popup opens: to its right, on the page."""
    x = max(0, min(a.rect.x1, p.rect.width - 200))
    y = max(0, min(a.rect.y0, p.rect.height - 100))
    return fitz.Rect(x, y, x + 200, y + 100)


def tidy(doc):
    """Make each comment one every reader opens: linked to its page, with a
    popup to read it in, and dates; drop popups whose comment is gone."""
    now = fitz.get_pdf_str(fitz.get_pdf_now())
    for p in doc:
        annots = refs(doc, p.xref, "Annots")
        keep = []
        for x in annots:
            t, parent = doc.xref_get_key(x, "Parent")
            if doc.xref_get_key(x, "Subtype")[1] == "/Popup" and t == "xref":
                parent = int(parent.split()[0])
                if parent not in annots:
                    continue
                if doc.xref_get_key(parent, "Popup")[0] == "null":
                    doc.xref_set_key(parent, "Popup", f"{x} 0 R")
            keep.append(x)
        if keep != annots:
            doc.xref_set_key(p.xref, "Annots", "[" + " ".join(f"{x} 0 R" for x in keep) + "]")
            p = doc.reload_page(p)
        for a in p.annots():
            if not is_comment(a) or a.type[0] == fitz.PDF_ANNOT_FREE_TEXT:
                continue
            if doc.xref_get_key(a.xref, "P")[0] == "null":
                doc.xref_set_key(a.xref, "P", f"{p.xref} 0 R")
            for key in ("CreationDate", "M"):
                if doc.xref_get_key(a.xref, key)[0] == "null":
                    doc.xref_set_key(a.xref, key, now)
            if doc.xref_get_key(a.xref, "Popup")[0] == "null":
                a.set_popup(beside(p, a))
            popup = int(doc.xref_get_key(a.xref, "Popup")[1].split()[0])
            if doc.xref_get_key(popup, "Open")[0] == "null":
                doc.xref_set_key(popup, "Open", "false")


def apply(r):
    file = r["file"]
    _, doc = document(file)
    try:
        added = change(doc, r["changes"])
        tidy(doc)
    except Exception:
        docs.pop(file, None)  # not half the changes in the next save
        raise
    if doc.can_save_incrementally():
        doc.saveIncr()
    else:
        tmp = file + ".pdfnvim-tmp"
        doc.save(tmp, garbage=1, deflate=True)
        os.replace(tmp, file)
    docs.pop(file, None)
    return dict(comments(r), added=added)


ops = dict(render=render, comments=comments, at=at, apply=apply, move=move)

for line in sys.stdin:
    r = json.loads(line)
    try:
        reply = ops[r.get("op", "render")](r)
    except Exception as e:
        reply = dict(error=f"{type(e).__name__}: {e}")
    reply["id"] = r.get("id")
    print(json.dumps(reply), flush=True)
