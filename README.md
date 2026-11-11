# pdf.nvim

`nvim file.pdf` shows the PDF's pages inside Neovim, drawn with iTerm2's
inline image protocol.

Scrolling has the terminal move the page up or down whole rows and draws only
the rows that come in, so it stays sharp and sends little. Zoomed in or fitting
the width, the pages are stacked a row apart and scrolling runs on from one into
the next. Pages are rendered
by a Python process kept running, which cuts each part from the page it has
drawn.

`:help pdf.nvim` has the keys, commands and settings.

Needs Neovim 0.12+, iTerm2 and a `python3` with [PyMuPDF](https://pymupdf.readthedocs.io)
(`pip install pymupdf`).

## Install

With vim-plug:

```vim
Plug 'ajccosta/pdf.nvim'
```

## Keys

| Keys                                | Does                                    |
|-------------------------------------|-----------------------------------------|
| `h` `j` `k` `l` arrows              | move the cursor over the page's text    |
| `w` `b` `e` `0` `^` `$` `{` `}`     | and the rest of Vim's motions           |
| `gg` `G`                            | first / last page (`3G`: page 3)        |
| `v` `V`, or a drag                  | select text (`V`: whole lines)          |
| `y`                                 | copy the text selected (`"+y`: clipboard) |
| CTRL-E CTRL-Y, wheel                | scroll down / up, on into the next page |
| CTRL-D CTRL-U                       | scroll half a window                    |
| `zh` `zl`, sideways wheel           | scroll left / right                     |
| `n` `p` Space BS PageDown PageUp    | next / previous page                    |
| `+` `=` `-`                         | zoom in / out                           |
| `zw`                                | fit the page's width                    |
| `zp`                                | fit the whole page                      |
| click                               | move the cursor there                   |
| click a comment                     | show its text                           |
| `c`                                 | comment on the text selected or at the cursor |
| `Esc`                               | let go of the selection                 |
| `C`                                 | the comments list, beside the page      |
| `m`                                 | hide or show the comments beside it     |

The cursor is a block over a character of the page, as in Vim; the page
scrolls to keep it in view. A count works: `3w` is three words on, `3n` three
pages, `2+` zooms in twice.

The wheel scrolls whichever window is under the mouse. `CTRL-W v` on the PDF
gives an empty window beside it for notes.

## Comments

Comments are the PDF's own notes (annotations), saved in the file, so Preview,
Skim and Acrobat show them too, and they show here on the page. Press `c` to
add one at the cursor, or select text first (`v`, or a drag) to comment on it:
it shows selected while you type, and is saved highlighted. Each comment's text shows
beside the page, as text in the window, on the row of what it is on and
joined to it by a line, on whichever side it fits best, in the room the page leaves (zoomed in,
it may leave none; fitting the width, the page stays taller than the window); `m` hides or shows them. Click a comment, or its
text, to read all of it.
Skim shows the text of comments from other programs only after File > Convert
Notes, which moves them out of the PDF. `C` (or `:PdfComments`) opens the list of them,
edited like a file:

```
p1 #1960  change this text to change the comment
p3 #1963  a comment over
    more than one line
p2 a new one on page 2
```

Change a line's text, delete it, or add one, then `:w` saves it into the PDF.
`<CR>` on a comment shows it on its page.

## Setup

```lua
require('pdf').setup({
  python = 'python3',  -- one with PyMuPDF
  scale = 2,           -- render at twice the screen size (retina)
  view = 'width',      -- open fitting the page's width (1: the whole page)
  smooth = true,       -- scroll by rows, drawing only the new ones
  continuous = true,   -- zoomed in: scroll on from page to page, no jump
  gap = 1,             -- rows between pages scrolled through
  scroll = 0.1,        -- CTRL-E and CTRL-Y move a tenth of the window
  half = 0.5,          -- CTRL-D and CTRL-U half of it
  wheel = 0.05,        -- a wheel tick a twentieth (at least a row)
  zoom = 1.25,         -- each zoom step
  comments_width = 40, -- the comments list's window
  notes_width = 40,     -- columns beside the page for comments (0: none)
  notes_min_width = 12, -- zoomed in, less room than this: no comments' text
  color = 'blue',       -- new comments' colour: a name in colors, or '#rrggbb'
  colors = { blue = '#89b4fa' },  -- names for colours, added to the defaults
  position = { 'right', 'center' },  -- where a page smaller than the window sits
  keys = { next = { 'n' } },  -- per action, replaces its keys
})
```

`:PdfPosition {across} [{down}]` moves the page while reading: `left`, `center`
or `right`, then `top`, `center` or `bottom`, or a fraction from 0 to 1
(`:PdfPosition 0.25`). `:PdfColor {name|#rrggbb}` picks new comments' colour
(`yellow`, `orange`, `red`, `pink`, `purple`, `blue`, `teal`, `green`). Both
choices are remembered across sessions. Each PDF opens where it was left: its page,
zoom and spot are remembered too, for the last 200 files.
