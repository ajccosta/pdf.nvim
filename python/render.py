# render.py: renders PDF pages for pdf.nvim, one JSON request per line on
# stdin, one JSON reply per line on stdout. Kept running, so documents stay
# open and a page drawn once is cut from for each scroll step.
#
# A request: {"id", "file", "page" (0-based), "width", "height" (the window, in
# pixels), "zoom", "x", "y", "out"}. It writes what the window shows of the page
# as a PNG at out. zoom 1 fits the whole page in the window, "width" fits its
# width; at more, the window shows the page from (x, y), in points from its
# top left corner.
#
# The reply: {"id", "count" (pages), "iw", "ih" (the image's size), "x", "y"
# (kept on the page), "mx", "my" (the most they can be), "vw", "vh" (the
# window's size in points), "pw", "ph" (the page's), "zoom"}, or {"id", "error"}.
import json
import os
import sys

import fitz

docs = {}  # by file: (mtime, document)
pages = {}  # (file, mtime, page, scale): the whole page drawn
MAX_PAGES = 6
MAX_PIXELS = 40_000_000  # past this, only the window's part is drawn


def document(file):
    mtime = os.stat(file).st_mtime
    if file not in docs or docs[file][0] != mtime:
        docs[file] = (mtime, fitz.open(file))
    return docs[file]


def whole_page(file, mtime, p, scale):
    key = (file, mtime, p.number, round(scale, 4))
    if key not in pages:
        while len(pages) >= MAX_PAGES:
            pages.pop(next(iter(pages)))
        pages[key] = p.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
    return pages[key]


def render(r):
    mtime, doc = document(r["file"])
    p = doc[max(0, min(int(r["page"]), doc.page_count - 1))]
    width, height = float(r["width"]), float(r["height"])
    pw, ph = p.rect.width, p.rect.height
    fit = min(width / pw, height / ph)
    zoom = max(1, width / pw / fit) if r["zoom"] == "width" else float(r["zoom"])
    scale = fit * zoom
    vw, vh = min(pw, width / scale), min(ph, height / scale)
    mx, my = pw - vw, ph - vh
    x, y = max(0, min(float(r["x"]), mx)), max(0, min(float(r["y"]), my))
    if pw * ph * scale * scale <= MAX_PIXELS:
        page = whole_page(r["file"], mtime, p, scale)
        x0, y0 = round(x * scale), round(y * scale)
        rect = fitz.IRect(x0, y0, min(page.width, x0 + round(vw * scale)), min(page.height, y0 + round(vh * scale)))
        pix = fitz.Pixmap(fitz.csRGB, rect, False)
        pix.copy(page, rect)
        pix.set_origin(0, 0)
    else:
        pix = p.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=fitz.Rect(x, y, x + vw, y + vh), alpha=False)
    pix.save(r["out"])
    return dict(count=doc.page_count, iw=pix.width, ih=pix.height, x=x, y=y, mx=mx, my=my,
                vw=vw, vh=vh, pw=pw, ph=ph, zoom=zoom)


for line in sys.stdin:
    r = json.loads(line)
    try:
        reply = render(r)
    except Exception as e:
        reply = dict(error=f"{type(e).__name__}: {e}")
    reply["id"] = r.get("id")
    print(json.dumps(reply), flush=True)
