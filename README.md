# pdf.nvim

`nvim file.pdf` shows the PDF's pages inside Neovim, drawn with iTerm2's
inline image protocol.

Scrolling has the terminal move the page up or down whole rows and draws only
the rows that come in, so it stays sharp and sends little. Pages are rendered
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
| `j` `k` Down Up, wheel              | scroll down / up, on to the next page   |
| `h` `l` Left Right, sideways wheel  | scroll left / right                     |
| `n` `p` Space BS PageDown PageUp    | next / previous page                    |
| `gg` `G` Home End                   | first / last page                       |
| `+` `=` `-`                         | zoom in / out                           |
| `w`                                 | fit the page's width                    |
| `0`                                 | fit the whole page                      |
| click a comment                     | show its text                           |
| click, then `c`                     | comment on that spot                    |
| drag, then `c`                      | comment on the text selected            |
| `Esc`                               | let go of the selection                 |
| `C`                                 | the comments list, beside the page      |

A count works: `3n` is three pages on, `2+` zooms in twice.

The wheel scrolls whichever window is under the mouse. `CTRL-W v` on the PDF
gives an empty window beside it for notes.

## Comments

Comments are the PDF's own notes (annotations), saved in the file, so Preview,
Skim and Acrobat show them too, and they show here on the page. Click a spot
and press `c` to add one, or drag over text first to comment on it: it shows
selected while you type, and is saved highlighted. Click a comment to read it.
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
  scroll = 0.2,        -- a scroll key moves a fifth of the window
  wheel = 0.05,        -- a wheel tick a twentieth (at least a row)
  zoom = 1.25,         -- each zoom step
  comments_width = 40, -- the comments list's window
  position = { 'right', 'center' },  -- where a page smaller than the window sits
  keys = { next = { 'n' } },  -- per action, replaces its keys
})
```

`:PdfPosition {across} [{down}]` moves the page while reading: `left`, `center`
or `right`, then `top`, `center` or `bottom`, or a fraction from 0 to 1
(`:PdfPosition 0.25`). The choice is remembered across sessions.
