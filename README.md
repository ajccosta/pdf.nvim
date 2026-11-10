# pdf.nvim

`nvim file.pdf` shows the PDF's pages inside Neovim, drawn with iTerm2's
inline image protocol.

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
  scroll = 0.2,        -- a scroll moves a fifth of the window
  zoom = 1.25,         -- each zoom step
  keys = { next = { 'n' } },  -- per action, replaces its keys
})
```
