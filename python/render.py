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
#   {"scale", "px", "py"}: the part of the page drawn at scale (pixels per
#     point) from (px, py), in pixels.
# Either way it writes a PNG at out, at most width x height. With "select"
# {"a", "b"} ({"x", "y"} on the page, in points), the text from a to b shows
# selected, and the reply's "selected" has it. The reply's "marks" are the
# page's comments, top to bottom, each {"id", "y": just under it, "side": where
# its text goes, "content", "color": "#rrggbb"}, and "commented" whether any
# page has one. With "links": {"cols": the text's width, "row": a row's height
# in pixels, "sides": ["left", "right"] or one}, each comment goes on the side
# where its text sits nearest its row, a line from it to that edge of the page.
#
# The reply: {"id", "count" (pages), "iw", "ih" (the image's size), "x", "y"
# (kept on the page), "mx", "my" (the most they can be), "vw", "vh" (the
# window's size), "pw", "ph" (the page's), all in points, "zoom", "scale",
# "px", "py", "pxw", "pxh" (the page's size in pixels), "notes" (comments on
# the page)}.
#
# comments: {"file"}: {"comments": the document's comments, each {"id", "page",
# "type", "content", "rect" (in points)}}.
#
# at: {"file", "page", "x", "y"}: {"comment": the one there, as comments has
# it, or null}.
#
# apply: {"file", "changes"}, each {"do": "add", "page", "x", "y", "content",
# "color": "#rrggbb" (optional)} (with "select" as render takes it, a
# highlight of that text, else a note),
# {"do": "set", "id", "content"} or {"do": "delete", "id"}: saves them into
# the PDF, then replies as comments does.
import getpass
import json
import os
import sys
import uuid

import fitz

docs = {}  # by file: (mtime, document)
pages = {}  # (file, mtime, page, links, scale): the whole page drawn
sheets = {}  # (file, mtime, page): the page with its links, to draw
words = {}  # (file, mtime, page): its words, in reading order
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


def page_words(file, mtime, p):
    key = (file, mtime, p.number)
    if key not in words:
        while len(words) >= MAX_PAGES:
            words.pop(next(iter(words)))
        found = sorted(p.get_text("words"), key=lambda w: (w[5], w[6], w[7]))
        words[key] = [(fitz.Rect(w[:4]) * p.rotation_matrix, fitz.Rect(w[:4]), w[4], (w[5], w[6])) for w in found]
    return words[key]


def selection(file, mtime, p, sel):
    """The words from sel's a to its b: their text, and a rect per line both
    as shown and on the unrotated page (for a highlight's quads)."""
    ws = page_words(file, mtime, p)
    if not ws:
        return "", [], []

    def nearest(pt):
        pt = fitz.Point(pt["x"], pt["y"])
        return min(range(len(ws)), key=lambda i: 0 if pt in ws[i][0] else pt.distance_to(ws[i][0]))

    i, j = sorted((nearest(sel["a"]), nearest(sel["b"])))
    lines = {}
    for shown, raw, _, line in ws[i:j + 1]:
        if line in lines:
            lines[line] = (lines[line][0] | shown, lines[line][1] | raw)
        else:
            lines[line] = (shown, raw)
    text = " ".join(w[2] for w in ws[i:j + 1])
    return text, [v[0] for v in lines.values()], [v[1] for v in lines.values()]


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
    found = marks(p, links, scale)
    src = sheet(r["file"], mtime, p, found) if links else p
    whole = pw * ph * scale * scale <= MAX_PIXELS
    page = whole_page(r["file"], mtime, p, links and sides_of(found), src, scale) if whole else None
    pxw, pxh = (page.width, page.height) if whole else (round(pw * scale), round(ph * scale))
    w, h = min(pxw, width), min(pxh, height)
    if "scale" in r:
        px, py = int(r["px"]), int(r["py"])
    else:
        px, py = round(float(r["x"]) * scale), round(float(r["y"]) * scale)
    px, py = max(0, min(px, pxw - w)), max(0, min(py, pxh - h))
    rect = fitz.IRect(px, py, px + w, py + h)
    if whole:
        pix = fitz.Pixmap(fitz.csRGB, rect, False)
        pix.copy(page, rect)
        pix.set_origin(0, 0)
    else:
        pix = src.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=fitz.Rect(rect) / scale, alpha=False)
    reply = {}
    if r.get("select"):
        text, rects, _ = selection(r["file"], mtime, p, r["select"])
        for rc in rects:
            box = (rc * scale).irect & fitz.IRect(0, 0, pxw, pxh)
            box = fitz.IRect(box.x0 - px, box.y0 - py, box.x1 - px, box.y1 - py) & pix.irect
            if not box.is_empty:
                pix.invert_irect(box)
        reply["selected"] = text
    pix.save(r["out"])
    found = [dict(id=a.xref, y=first.y1 + 1, side=side, content=a.info.get("content", ""),
                  color="#%02x%02x%02x" % tuple(round(c * 255) for c in color)) for a, first, color, side in found]
    return dict(reply, notes=len(found), marks=found, commented=has_comments(r["file"], mtime, doc), count=doc.page_count, iw=pix.width, ih=pix.height, x=px / scale, y=py / scale,
                mx=(pxw - w) / scale, my=(pxh - h) / scale, vw=w / scale, vh=h / scale, pw=pw, ph=ph,
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
    _, doc = document(r["file"])
    p = doc[int(r["page"])]
    pt = fitz.Point(float(r["x"]), float(r["y"]))
    hits = [a for a in p.annots() if is_comment(a) and covers(p, a, pt)]
    return dict(comment=describe(p, hits[-1]) if hits else None)


def find(doc, xref):
    for p in doc:
        for a in p.annots():
            if a.xref == xref:
                return p, a
    raise KeyError(f"no comment #{xref}")


def change(doc, changes):
    file = doc.name
    for c in changes:
        if c["do"] == "add":
            p = doc[int(c["page"])]
            quads = c.get("select") and selection(file, os.stat(file).st_mtime, p, c["select"])[2]
            if quads:
                a = p.add_highlight_annot(quads)
                # where readers that open a note in a popup (Preview) show it
                x = max(0, min(a.rect.x1, p.rect.x1 - 200))
                a.set_popup(fitz.Rect(x, a.rect.y0, x + 200, a.rect.y0 + 100))
            else:
                # x, y are where it shows; the note's point is on the unrotated page
                # (kept on the page)
                x = max(0, min(float(c["x"]), p.rect.width - 20))
                y = max(0, min(float(c["y"]), p.rect.height - 20))
                at = fitz.Point(x, y) * p.derotation_matrix
                a = p.add_text_annot(at, c["content"], icon="Comment")
            a.set_info(content=c["content"], title=getpass.getuser())
            if c.get("color"):
                a.set_colors(stroke=[int(c["color"][i:i + 2], 16) / 255 for i in (1, 3, 5)])
            a.update()
            # its own name: PyMuPDF's start again with each opening
            doc.xref_set_key(a.xref, "NM", fitz.get_pdf_str(str(uuid.uuid4())))
        elif c["do"] == "set":
            _, a = find(doc, int(c["id"]))
            a.set_info(content=c["content"])
            a.update()
        elif c["do"] == "delete":
            p, a = find(doc, int(c["id"]))
            p.delete_annot(a)


def apply(r):
    file = r["file"]
    _, doc = document(file)
    try:
        change(doc, r["changes"])
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
    return comments(r)


ops = dict(render=render, comments=comments, at=at, apply=apply)

for line in sys.stdin:
    r = json.loads(line)
    try:
        reply = ops[r.get("op", "render")](r)
    except Exception as e:
        reply = dict(error=f"{type(e).__name__}: {e}")
    reply["id"] = r.get("id")
    print(json.dumps(reply), flush=True)
