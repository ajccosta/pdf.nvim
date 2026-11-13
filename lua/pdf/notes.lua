-- The comments' text beside the page, in floats either side of it.
local config = require('pdf.config')
local util = require('pdf.util')
local N = {}

-- margin(st, cols, rows, cpx, rpx): how many of a window's cols go to the
-- comments' text on each side of the page: none when hidden (`m`), the PDF
-- has none or the window is narrow; and zoomed in, only what the page leaves
-- (none under notes_min_width), so they never cover it. Fitting the width,
-- only what leaves the page taller than the window, so it scrolls by rows.
-- Where the page leaves more room beside it, they take that too, up to
-- notes_max_width, all but notes_gutter columns for their lines.
function N.margin(st, cols, rows, cpx, rpx)
  local w = config.notes_width
  if st.margin == false or not st.commented or w <= 0 or cols - 2 * w < 20 then
    return 0
  end
  if not st.pw then
    return w
  end
  local k = math.min(2, 1 / (1 - util.fraction(config.position[1])))
  -- room(n): the page's columns when the comments get n
  local function room(n)
    return cols - math.floor(n * k)
  end
  -- fits(r): whether the page fits r columns of room; page(r): its columns
  local fits, page
  if type(st.zoom) == 'number' then
    -- its width at its zoom within the room
    page = function(r)
      return st.pw * math.min(r * cpx / st.pw, rows * rpx / st.ph) * st.zoom / cpx
    end
    fits = function(r)
      return page(r) <= r + 0.01
    end
  elseif room(0) * cpx * st.ph / st.pw <= rows * rpx then
    -- the whole width shows all of it: nothing to scroll anyway
    page = function(r)
      return math.min(r, rows * rpx * st.pw / st.ph / cpx)
    end
    fits = function()
      return true
    end
  else
    -- taller than the window at the room's width, which it fills
    page = function(r)
      return r
    end
    fits = function(r)
      return r * cpx * st.ph / st.pw > rows * rpx
    end
  end
  for n = w, config.notes_min_width, -1 do
    if fits(room(n)) then
      -- more, while the page leaves room for it and the lines
      while n < config.notes_max_width and n + 1 <= (cols - 20) / 2 and fits(room(n + 1))
        and room(n + 1) - page(room(n + 1)) >= config.notes_gutter * k do
        n = n + 1
      end
      return n
    end
  end
  return 0
end

local ns = vim.api.nvim_create_namespace('pdf.nvim')
vim.api.nvim_set_hl(0, 'PdfNote', { default = true, link = 'Normal' })

-- hl(color): the highlight group in color ("#rrggbb"), defined once: defining
-- one redraws the whole screen, too slow for each scroll step.
local colored = {}
function N.hl(color)
  local name = 'PdfNote' .. color:sub(2)
  if not colored[name] then
    vim.api.nvim_set_hl(0, name, { fg = color })
    colored[name] = true
  end
  return name
end

-- The left side's text is the right side's in a mirror: its lines end where
-- those start, and its connectors turn the other way.
local mirrored = {}
for a, b in pairs({ ['╮'] = '╭', ['╰'] = '╯', ['┐'] = '┌', ['┘'] = '└', ['┤'] = '├' }) do
  mirrored[a], mirrored[b] = b, a
end

-- Each side's text is in a float of its own beside the page, not in the
-- page's window: nvim redraws a changed row from its first change to its
-- last, and in one window that would cross the page and erase it.
local sides = {} -- win: { left = float, right = float }

-- Windows over a window's comments (an editor over its box): win: { [float]
-- = follow(sh), which moves it where they are drawn now }.
local over = {}

-- follow(win, float, f): f(sh) each time win's comments are drawn again (sh:
-- what win shows), while float is open.
function N.follow(win, float, f)
  over[win] = over[win] or {}
  over[win][float] = f
end

-- covered(win): whether a window is over win's comments; its rows then must
-- not roll, which would move it too, where nvim does not know.
function N.covered(win)
  for f in pairs(over[win] or {}) do
    if vim.api.nvim_win_is_valid(f) then
      return true
    end
    over[win][f] = nil
  end
  return false
end

-- unnote(win): close win's floats for its comments' text.
function N.unnote(win)
  for _, f in pairs(sides[win] or {}) do
    if vim.api.nvim_win_is_valid(f) then
      vim.api.nvim_win_close(f, true)
    end
  end
  sides[win] = nil
end

-- beside(win, side, col, width): side's float over win's columns col on, of
-- width, cleared; its buffer, or nil when it has no room.
local function beside(win, side, col, width)
  sides[win] = sides[win] or {}
  local f = sides[win][side]
  if width < 1 then
    if f and vim.api.nvim_win_is_valid(f) then
      vim.api.nvim_win_close(f, true)
    end
    sides[win][side] = nil
    return
  end
  local height = vim.api.nvim_win_get_height(win)
  local config = { relative = 'win', win = win, row = 0, col = col, width = width, height = height }
  if f and vim.api.nvim_win_is_valid(f) then
    vim.api.nvim_win_set_config(f, config)
  else
    local buf = vim.api.nvim_create_buf(false, true)
    f = vim.api.nvim_open_win(buf, false, vim.tbl_extend('force', config, {
      focusable = false, mouse = false, style = 'minimal', zindex = 1, noautocmd = true,
    }))
    vim.wo[f].winhighlight = 'NormalFloat:Normal'
    sides[win][side] = f
  end
  local buf = vim.api.nvim_win_get_buf(f)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if vim.api.nvim_buf_line_count(buf) ~= height then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ '' }, height))
  end
  return buf
end

-- clip(lines, most): at most most of lines, the last ending in … when there
-- are more
local function clip(lines, most)
  if #lines <= most then
    return lines
  end
  lines = vim.list_slice(lines, 1, most)
  local w = vim.fn.strdisplaywidth(lines[most])
  lines[most] = vim.fn.strcharpart(lines[most], 0, w - 1):gsub('[%s%p]+$', '') .. '…'
  return lines
end

-- place(items, height): each of a side's items, top to bottom ({ row: of what
-- it is on, text: its lines }), its box: .lines, at most notes_lines of its
-- text, or fewer when that leaves them all within height rows; .t, its top,
-- in order and apart, within height when they fit and, all told, as near as
-- they can be to each first line on its row (least squares: runs of boxes
-- that would overlap go where their rows are on average); .into, the row its
-- line goes into it, its own row when the box is there.
local function place(items, height)
  local most = config.notes_lines
  if most <= 0 then
    most = 1
    for _, it in ipairs(items) do
      most = math.max(most, #it.text)
    end
  end
  local function rows(most)
    local n = 0
    for _, it in ipairs(items) do
      n = n + math.max(math.min(#it.text, most), 1) + 2
    end
    return n
  end
  while most > 1 and rows(most) > height do
    most = most - 1
  end
  -- with the rows of the boxes above each taken out, the tops must only not
  -- go up: pool adjacent ones that would
  local above, runs = 0, {}
  for i, it in ipairs(items) do
    it.lines = clip(#it.text > 0 and it.text or { '' }, most)
    it.above = above
    above = above + #it.lines + 2
    runs[#runs + 1] = { sum = it.row - 1 - it.above, n = 1, from = i }
    while #runs > 1 and runs[#runs - 1].sum / runs[#runs - 1].n > runs[#runs].sum / runs[#runs].n do
      local last = table.remove(runs)
      runs[#runs].sum, runs[#runs].n = runs[#runs].sum + last.sum, runs[#runs].n + last.n
    end
  end
  for _, run in ipairs(runs) do
    local t = math.max(math.min(math.floor(run.sum / run.n + 0.5), height - above), 0)
    for i = run.from, run.from + run.n - 1 do
      local it = items[i]
      it.t = t + it.above
      it.into = math.max(math.min(it.row, it.t + #it.lines), it.t + 1)
    end
  end
end

-- route(items): for each item whose line goes up or down to its box, .lane,
-- how many columns left of the boxes its vertical runs (from 0), so that no
-- two lines cross: right of the lines whose start it passes, left of those
-- whose end it passes.
local function route(items)
  local bent = vim.tbl_filter(function(it) return it.into ~= it.row end, items)
  local nearer = {} -- { a, b }: a's lane nearer the boxes than b's
  for _, a in ipairs(bent) do
    a.lane = 0
    local lo, hi = math.min(a.row, a.into), math.max(a.row, a.into)
    for _, b in ipairs(bent) do
      if b ~= a and b.row ~= a.row and b.row >= lo and b.row <= hi then
        nearer[#nearer + 1] = { a, b }
      end
      if b ~= a and b.into >= lo and b.into <= hi then
        nearer[#nearer + 1] = { b, a }
      end
    end
  end
  for _ = 1, #bent do
    for _, n in ipairs(nearer) do
      n[2].lane = math.max(n[2].lane, n[1].lane + 1)
    end
  end
end

-- draw(win, sh): the comments on the pages win shows (sh: what it shows) as
-- text beside them, each in a box in its colour, placed by place() over all
-- of the window's rows, a line in that colour from the row of where it is. A
-- line that has to go up or down to its box does so in a lane of its own
-- (route()), so lines never cross or merge.
-- Laid out as on the right, then mirrored for the left.
local function draw(win, sh)
  if not sh or not vim.api.nvim_win_is_valid(win) then
    return N.unnote(win)
  end
  sh.noted, sh.boxes, sh.layout = { left = {}, right = {} }, {}, nil
  if sh.margin == 0 then
    return N.unnote(win)
  end
  local info = vim.fn.getwininfo(win)[1]
  local b = sh.box
  local cols = info.width - info.textoff
  local first = b.row - info.winrow -- the page's first row in the window
  local left = b.col - info.wincol - info.textoff -- the page's first column
  local past = { right = left + b.w, left = cols - left } -- the column past it
  local to = cols - sh.margin + 1 -- the text's column
  local bufs = {
    left = beside(win, 'left', info.textoff, left),
    right = beside(win, 'right', info.textoff + past.right, cols - past.right),
  }
  -- put(side, row, col, s, hl, m, w): s at row and col as laid out on the
  -- right; on the left, w (s's width when none) wide, ending where it starts
  local function put(side, row, col, s, hl, m, w)
    if row < 0 or row >= info.height or not bufs[side] then
      return
    end
    if side == 'left' then
      w = w or vim.fn.strdisplaywidth(s)
      if not m then
        s = vim.fn.join(vim.tbl_map(function(c) return mirrored[c] or c end, vim.fn.reverse(vim.fn.split(s, '\\zs'))), '')
      end
      col = cols - col - w
    else
      col = col - past.right
    end
    vim.api.nvim_buf_set_extmark(bufs[side], ns, row, 0,
      { virt_text = { { s, hl } }, virt_text_win_col = col, virt_text_pos = 'overlay' })
    sh.noted[side][row] = m or sh.noted[side][row]
  end
  local found = {} -- the comments of the pages shown, top to bottom
  local pages = vim.tbl_keys(sh.pages)
  table.sort(pages)
  for _, n in ipairs(pages) do
    for _, m in ipairs(sh.pages[n].marks) do
      found[#found + 1] = vim.tbl_extend('force', m, { top = sh.pages[n].top, page = n })
    end
  end
  local width = sh.margin - 4 -- of the text in a box, a column of room each side
  local on = { left = {}, right = {} } -- each side's items, as place() takes them
  for _, m in ipairs(found) do
    local row = first + math.floor((m.top + m.y * sh.scale - sh.py) / sh.rpx)
    if row >= first and row < first + b.h then
      table.insert(on[m.side], { m = m, row = row, text = util.wrap(util.text(m.content), width) })
    end
  end
  local bar = string.rep('─', sh.margin - 2)
  sh.layout = { textoff = info.textoff, to = to, first = first }
  for side, items in pairs(on) do
    place(items, info.height)
    route(items)
    local from = past[side]
    for _, it in ipairs(items) do
      local m, t = it.m, it.t
      local hl = N.hl(m.color)
      sh.boxes[m.id] = { side = side, t = t, hl = hl, height = #it.lines }
      put(side, t, to - 1, '┌' .. bar .. '┐', hl)
      for i, l in ipairs(it.lines) do
        put(side, t + i, to - 1, t + i == it.into and '┤' or '│', hl)
        put(side, t + i, to + 1, l, 'PdfNote', m, width)
        put(side, t + i, cols - 1, '│', hl)
      end
      put(side, t + #it.lines + 1, to - 1, '└' .. bar .. '┘', hl)
      if it.into == it.row then
        put(side, it.row, from, string.rep('─', to - 1 - from), hl)
      else
        local lane = math.max(to - 2 - it.lane, math.min(from + 1, to - 2), from)
        local down = it.into > it.row
        put(side, it.row, from, string.rep('─', lane - from) .. (down and '╮' or '╯'), hl)
        for r = math.min(it.row, it.into) + 1, math.max(it.row, it.into) - 1 do
          put(side, r, lane, '│', hl)
        end
        put(side, it.into, lane, (down and '╰' or '╭') .. string.rep('─', to - 2 - lane), hl)
      end
    end
  end
end

function N.draw(win, sh)
  draw(win, sh)
  if N.covered(win) and sh then
    for _, f in pairs(over[win]) do
      f(sh)
    end
  end
end

-- box(sh, id, at): where to edit in place the comment id of the window sh
-- is what it shows: over its box beside the page; with no id, a new one's,
-- right of the row of at ({ page, y }). { row, col: its border's corner in
-- the window, width, height: inside it, hl: its border's highlight, nil for
-- a new one }; nil when the comment has no box shown, or there is no room.
function N.box(sh, id, at)
  local l = sh and sh.layout
  if not l then
    return
  end
  local box = id and sh.boxes[id]
  if not box then
    local g = at and sh.pages[at.page]
    if id or not g then
      return
    end
    local row = l.first + math.floor((g.top + at.y * sh.scale - sh.py) / sh.rpx)
    box = { side = 'right', t = math.max(row - 1, 0), height = 1 }
  end
  return {
    row = box.t, col = l.textoff + (box.side == 'right' and l.to - 1 or 0), width = sh.margin - 2,
    height = box.height, hl = box.hl,
  }
end

-- clear(win): take win's comments' text off the screen, to draw it again
-- where the page's rows move it.
function N.clear(win)
  for _, f in pairs(sides[win] or {}) do
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(f), ns, 0, -1)
  end
end

return N
