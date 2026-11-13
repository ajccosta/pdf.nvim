# Terminals

pdf.nvim draws each page as an image, so it needs a terminal that can show
images. It finds which one it runs in by itself, and speaks either of the two
image protocols terminals use: iTerm2's (`protocol = 'iterm'`) or Kitty's
(`protocol = 'kitty'`). Set `protocol` in `setup()` only if it guesses wrong.

These were tried on macOS, with the plugin opening a PDF, scrolling through
it both ways, and leaving it for another buffer.

## Work as they are

- **[iTerm2](https://iterm2.com)**: iTerm2's protocol.
- **[Ghostty](https://ghostty.org)**: Kitty's protocol.
- **[Kitty](https://sw.kovidgoyal.net/kitty)**: Kitty's protocol.
- **[WezTerm](https://wezterm.org)**: iTerm2's protocol.
- **[Rio](https://rioterm.com)**: iTerm2's protocol.

## VS Code

VS Code's built-in terminal shows images once you turn them on. Open
Settings (Cmd-,), search for `enableImages` and tick **Terminal › Integrated:
Enable Images**, or add this to your `settings.json`:

```json
"terminal.integrated.enableImages": true
```

Then open a new terminal (the ones already open keep the old setting) and run
`nvim paper.pdf` in it. The terminal panel is small by default, so maximise it
(the `^` button on the panel's title bar) to see more of the page.

## Don't work

- **Terminal**, macOS's own, and **[Tabby](https://tabby.sh)**: neither can
  show images. nvim opens, but the page stays blank.

## Not tried

- **[Warp](https://www.warp.dev)** asks you to go through its onboarding
  before it opens a terminal, so it wasn't tried. If you use it, tell us how
  it goes in an issue.

Any other terminal that supports iTerm2's or Kitty's image protocol should
work too; if pdf.nvim doesn't detect it, set `protocol` yourself:

```lua
require('pdf').setup({ protocol = 'kitty' })  -- or 'iterm'
```
