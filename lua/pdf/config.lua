-- The options, as setup takes them. One table, which setup changes in place,
-- so each module's reference to it sees the changes.
return {
  python = 'python3', -- one with PyMuPDF (`pip install pymupdf`)
  -- how the terminal draws images: 'iterm' (iTerm2, WezTerm, Rio, VS Code),
  -- 'kitty' (Kitty, Ghostty), or 'auto', the terminal's
  protocol = 'auto',
  cell = { 9, 18 }, -- a cell's size in pixels to draw at (the width as the terminal's cells are shaped)
  scale = 2, -- render this many times the screen size (retina)
  scale_scrolling = 1, -- and this many while scrolling, which is faster
  sharp_after = 150, -- ms without scrolling before the sharp frame
  -- scroll by having the terminal move the page up or down whole rows and
  -- drawing only the rows that come in: sharp all along, and little to send
  smooth = true,
  -- zoomed in or fitting the width, scroll on from one page into the next,
  -- gap rows apart, instead of jumping to it
  continuous = true,
  gap = 1,
  view = 'width', -- a PDF opens fitting its width; 1 fits the whole page
  split_empty = true, -- a split of a PDF's window (CTRL-W v) starts empty
  -- where the page sits when it is smaller than the window: across (left,
  -- center, right) and down (top, center, bottom), or a fraction from 0 to 1
  position = { 'right', 'center' },
  scroll = 0.1, -- a scroll key (CTRL-E, CTRL-Y) moves this much of the window
  half = 0.5, -- and CTRL-D, CTRL-U this much
  wheel = 0.05, -- and a wheel tick this much
  zoom = 1.25, -- a zoom in or out multiplies by this
  comments_width = 40, -- the comments list's window, in columns
  editor_height = 8, -- at most this many lines for a comment edited below the PDF (no room beside it)
  notes_width = 40, -- columns each side of the page for its comments; 0: none
  notes_min_width = 12, -- zoomed in, fewer than this left beside the page: none
  notes_max_width = 80, -- with more room beside the page, they take up to this
  notes_gutter = 8, -- of that room, the columns left between page and comments
  notes_lines = 0, -- rows of each comment's text beside the page, at most; 0: all of it
  -- (either way, fewer when the comments would not all fit in the window)
  -- new comments' colour: a name from colors or "#rrggbb"; see :PdfColor
  color = 'blue',
  colors = {
    yellow = '#ffe873', orange = '#fab387', red = '#f38ba8', pink = '#f5c2e7',
    purple = '#cba6f7', blue = '#89b4fa', teal = '#94e2d5', green = '#a6e3a1',
  },
  keys = {
    next = { 'n', '<Space>', '<PageDown>' },
    prev = { 'p', '<BS>', '<PageUp>' },
    -- the text cursor's motions, as in Vim; see pdf.cursor's motions
    left = { 'h', '<Left>' },
    right = { 'l', '<Right>' },
    down = { 'j', '<Down>' },
    up = { 'k', '<Up>' },
    word = { 'w' },
    word_end = { 'e' },
    word_back = { 'b' },
    line_start = { '0', '<Home>' },
    line_text = { '^' },
    line_end = { '$', '<End>' },
    paragraph_next = { '}' },
    paragraph_prev = { '{' },
    first = { 'gg' },
    last = { 'G' },
    screen_top = { 'H' },
    screen_middle = { 'M' },
    screen_bottom = { 'L' },
    find = { 'f' },
    find_back = { 'F' },
    till = { 't' },
    till_back = { 'T' },
    search = { '/' },
    search_back = { '?' },
    search_next = { 'n' },
    search_prev = { 'N' },
    find_next = { ';' },
    find_prev = { ',' },
    jump_back = { '<C-o>' },
    jump_forward = { '<C-i>', '<Tab>' },
    visual = { 'v' },
    visual_lines = { 'V' },
    yank = { 'y' },
    scroll_down = { '<C-e>' },
    scroll_up = { '<C-y>' },
    half_down = { '<C-d>' },
    half_up = { '<C-u>' },
    scroll_left = { 'zh' },
    scroll_right = { 'zl' },
    wheel_down = { '<ScrollWheelDown>' },
    wheel_up = { '<ScrollWheelUp>' },
    wheel_left = { '<ScrollWheelLeft>' },
    wheel_right = { '<ScrollWheelRight>' },
    zoom_in = { '+', '=' },
    zoom_out = { '-' },
    fit = { 'zp' },
    fit_width = { 'zw' },
    point = { '<LeftMouse>' },
    drag = { '<LeftDrag>' },
    release = { '<LeftRelease>', '<2-LeftRelease>' },
    edit_click = { '<2-LeftMouse>' },
    clear = { '<Esc>' },
    comment = { 'c' },
    delete = { 'x' },
    undo = { 'u' },
    redo = { '<C-r>' },
    comments = { 'C' },
    margin = { 'm' },
  },
  -- in the comments list
  list_keys = {
    jump = { '<CR>' },
  },
}
