# render.py PDF PAGE WIDTH HEIGHT ZOOM X Y OUT: the part of page PAGE (0-based)
# of PDF a WIDTH x HEIGHT pixel window shows, as a PNG at OUT. ZOOM 1 fits the
# whole page in the window, `width` fits its width; at more, the window shows the page from (X, Y), in
# points from its top left corner.
#
# Prints the page count, the image's width and height, X and Y kept on the
# page, the most they can be, the window's size and the page's, in points, and the zoom.
import sys

import fitz

pdf, page, width, height, zoom, x, y, out = sys.argv[1:9]
width, height, x, y = float(width), float(height), float(x), float(y)
doc = fitz.open(pdf)
p = doc[max(0, min(int(page), doc.page_count - 1))]
pw, ph = p.rect.width, p.rect.height
fit = min(width / pw, height / ph)
zoom = max(1, width / pw / fit) if zoom == 'width' else float(zoom)
scale = fit * zoom
# the window, in points
vw, vh = min(pw, width / scale), min(ph, height / scale)
mx, my = pw - vw, ph - vh
x, y = max(0, min(x, mx)), max(0, min(y, my))
clip = fitz.Rect(x, y, x + vw, y + vh)
pix = p.get_pixmap(matrix=fitz.Matrix(scale, scale), clip=clip, alpha=False)
pix.save(out)
print(doc.page_count, pix.width, pix.height, x, y, mx, my, vw, vh, pw, ph, zoom)
