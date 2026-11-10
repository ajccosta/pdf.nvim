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

| Keys                                   | Page     |
|----------------------------------------|----------|
| `n` `j` `l` Space PageDown Down wheel  | next     |
| `p` `k` `h` BS PageUp Up wheel         | previous |
| `gg` Home                              | first    |
| `G` End                                | last     |

A count works: `3n` is three pages on.

## Setup

```lua
require('pdf').setup({
  python = 'python3',  -- one with PyMuPDF
  scale = 2,           -- render at twice the screen size (retina)
  keys = { next = { 'n' } },  -- per action, replaces its keys
})
```
