# render.py PDF PAGE WIDTH HEIGHT OUT: page PAGE (0-based) of PDF as a PNG at
# OUT, as large as fits in WIDTH x HEIGHT pixels. Prints the page count and
# the image's width and height.
import sys

import fitz

pdf, page, width, height, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
doc = fitz.open(pdf)
p = doc[max(0, min(page, doc.page_count - 1))]
zoom = min(width / p.rect.width, height / p.rect.height)
pix = p.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
pix.save(out)
print(doc.page_count, pix.width, pix.height)
