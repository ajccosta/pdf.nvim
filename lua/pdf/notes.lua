-- The comments' text beside the page, in floats either side of it.
local config = require('pdf.config')
local util = require('pdf.util')
local N = {}

-- margin(st, cols, rows, cpx, rpx): how many of a window's cols go to the
-- comments' text on each side of the page: none when hidden (`m`), the PDF
-- has none or the window is narrow; and zoomed in, only what the page leaves
-- (none under notes_min_width), so they never cover it. Fitting the width,
-- only what leaves the page taller than the window, so it scrolls by rows.
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
  local fits
  if type(st.zoom) == 'number' then
    -- its width at its zoom within the room
    fits = function(r)
      return st.pw * math.min(r * cpx / st.pw, rows * rpx / st.ph) * st.zoom / cpx <= r + 0.01
    end
  elseif room(0) * cpx * st.ph / st.pw <= rows * rpx then
    return w -- the whole width shows all of it: nothing to scroll anyway
  else
    -- taller than the window at the room's width
    fits = function(r)
      return r * cpx * st.ph / st.pw > rows * rpx
    end
  end
  for n = w, config.notes_min_width, -1 do
    if fits(room(n)) then
      return n
    end
  end
  return 0
end

local ns = vim.api.nvim_create_namespace('pdf.nvim')
vim.api.nvim_set_hl(0, 'PdfNote', { default = true, link = 'Normal' })

-- The left side's text is the right side's in a mirror: its lines end where
-- those start, and its connectors turn the other way.
local mirrored = { ['╮'] = '╭', ['╰'] = '╯' }

-- Each side's text is in a float of its own beside the page, not in the
-- page's window: nvim redraws a changed row from its first change to its
-- last, and in one window that would cross the page and erase it.
local sides = {} -- win: { left = float, right = float }

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

-- draw(win, sh): the comments on the pages win shows (sh: what it shows) as text beside them, each on the row
-- of where it is (or below the one before on its side), a line in its colour
-- from there. Laid out as on the right, then mirrored for the left.
function N.draw(win, sh)
  if not sh or not vim.api.nvim_win_is_valid(win) then
    return N.unnote(win)
  end
  sh.noted = { left = {}, right = {} }
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
  local function put(side, row, col, s, hl, m)
    if row >= info.height or not bufs[side] then
      return
    end
    if side == 'left' then
      local w = vim.fn.strdisplaywidth(s)
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
  local below = { left = 0, right = 0 }
  local found = {} -- the comments of the pages shown, top to bottom
  local pages = vim.tbl_keys(sh.pages)
  table.sort(pages)
  for _, n in ipairs(pages) do
    for _, m in ipairs(sh.pages[n].marks) do
      found[#found + 1] = vim.tbl_extend('force', m, { top = sh.pages[n].top, page = n })
    end
  end
  for _, m in ipairs(found) do
    local side, from = m.side, past[m.side]
    local row = first + math.floor((m.top + m.y * sh.scale - sh.py) / sh.rpx)
    if row >= first and row < first + b.h then
      local hl = 'PdfNote' .. m.color:sub(2)
      vim.api.nvim_set_hl(0, hl, { fg = m.color })
      local t = math.max(row, below[side])
      if t == row then
        put(side, row, from, string.rep('─', to - from), hl)
      else
        put(side, row, from, string.rep('─', to - 2 - from) .. '╮', hl)
        for r = row + 1, t - 1 do
          put(side, r, to - 2, '│', hl)
        end
        put(side, t, to - 2, '╰─', hl)
      end
      local lines = util.wrap(util.text(m.content), sh.margin - 2)
      for i, l in ipairs(lines) do
        put(side, t + i - 1, to + 1, l, 'PdfNote', m)
      end
      below[side] = t + #lines + 1
    end
  end
end

-- clear(win): take win's comments' text off the screen, to draw it again
-- where the page's rows move it.
function N.clear(win)
  for _, f in pairs(sides[win] or {}) do
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(f), ns, 0, -1)
  end
end

return N
