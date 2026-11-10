# pdf.nvim

`nvim file.pdf` shows the PDF's pages inside Neovim, drawn with iTerm2's
inline image protocol.

Pages are rendered by a Python process kept running, which cuts each scroll
step from the page it has drawn: a frame takes some 35 ms while scrolling, then
a sharp one follows once it stops.

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

A count works: `3n` is three pages on, `2+` zooms in twice.

## Setup

```lua
require('pdf').setup({
  python = 'python3',  -- one with PyMuPDF
  scale = 2,           -- render at twice the screen size (retina)
  view = 'width',      -- open fitting the page's width (1: the whole page)
  scale_scrolling = 1, -- render at screen size while scrolling (faster)
  scroll = 0.2,        -- a scroll key moves a fifth of the window
  wheel = 0.05,        -- a wheel tick a twentieth
  zoom = 1.25,         -- each zoom step
  keys = { next = { 'n' } },  -- per action, replaces its keys
})
```
