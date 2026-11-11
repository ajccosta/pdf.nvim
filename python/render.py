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
# selected, and the reply's "selected" has it.
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
# apply: {"file", "changes"}, each {"do": "add", "page", "x", "y", "content"}
# (with "select" as render takes it, a highlight of that text, else a note),
# {"do": "set", "id", "content"} or {"do": "delete", "id"}: saves them into
# the PDF, then replies as comments does.
import getpass
import json
import os
import sys
import uuid

import fitz

docs = {}  # by file: (mtime, document)
pages = {}  # (file, mtime, page, scale): the whole page drawn
words = {}  # (file, mtime, page): its words, in reading order
MAX_PAGES = 6
MAX_PIXELS = 40_000_000  # past this, only the part asked for is drawn


def document(file):
    mtime = os.stat(file).st_mtime
    if file not in docs or docs[file][0] != mtime:
        docs[file] = (mtime, fitz.open(file))
    return docs[file]


def whole_page(file, mtime, p, scale):
    key = (file, mtime, p.number, round(scale, 6))
    if key not in pages:
        while len(pages) >= MAX_PAGES:
            pages.pop(next(iter(pages)))
        pages[key] = p.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
    return pages[key]


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
    whole = pw * ph * scale * scale <= MAX_PIXELS
    page = whole_page(r["file"], mtime, p, scale) if whole else None
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
        pix = p.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=fitz.Rect(rect) / scale, alpha=False)
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
    notes = sum(1 for a in p.annots() if is_comment(a))
    return dict(reply, notes=notes, count=doc.page_count, iw=pix.width, ih=pix.height, x=px / scale, y=py / scale,
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
                at = fitz.Point(float(c["x"]), float(c["y"])) * p.derotation_matrix
                a = p.add_text_annot(at, c["content"], icon="Comment")
            a.set_info(content=c["content"], title=getpass.getuser())
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
