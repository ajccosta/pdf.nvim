-- What each window shows of its PDF: drawing it, scrolling and zooming it.
local config = require('pdf.config')
local notes = require('pdf.notes')
local renderer = require('pdf.renderer')
local util = require('pdf.util')
local V = {}

local function status(st)
  if st.selected then
    local t = vim.fn.strcharpart(st.selected, 0, 50)
    return vim.api.nvim_echo({ { string.format('selected "%s%s": c comments on it, y copies it, <Esc> lets go', t,
      t == st.selected and '' or '…') } }, false, {})
  end
  local zoom = math.abs(st.zoom - 1) < 0.01 and '' or string.format('  %d%%', st.zoom * 100)
  local notes = (st.notes or 0) > 0 and string.format('  %d comment%s', st.notes, st.notes > 1 and 's' or '') or ''
  vim.api.nvim_echo({ { string.format('page %d/%d%s%s', st.page + 1, st.count or 0, zoom, notes) } }, false, {})
end

-- draw(win, clear, scale): render win's page and draw it. nvim's own redraw
-- (:mode) wipes the old image first when clear is set or the image's cells
-- change; otherwise the new image covers the old one, without a flicker.
-- What each window shows, from its last whole frame on: its page, scale,
-- offset in pixels (py), where its scroll is going (target), and its cells.
local shown = {}
V.shown = shown

-- selected(st): the text selected, as render takes it: from where v (or V,
-- whole lines) started to the cursor.
function V.selected(st)
  local v, c = st.visual, st.cursor
  return v and c and { page = v.page, a = { x = v.x, y = v.y }, b = { x = c.x, y = c.y }, lines = v.lines } or nil
end

-- continuous(st): whether st's pages show stacked, one on from the other.
function V.continuous(st)
  return config.continuous and st.zoom ~= 1
end

-- page_at(sh, py): the page at sh's pixel row py, and where in it in points.
function V.page_at(sh, py)
  local page = sh.page
  if sh.tops then
    for i, top in ipairs(sh.tops) do
      if top > py then
        break
      end
      page = i - 1
    end
  end
  return page, (py - (sh.tops and sh.tops[page + 1] or 0)) / sh.scale
end

local function draw(win, clear, scale)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local st = vim.b[buf].pdf
  if not st then
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  local cols, rows = info.width - info.textoff, info.height
  -- the page sits where position says in all of the window, its comments'
  -- text right of it: the page gets what leaves room for that
  -- the last screen row scrolls the terminal
  rows = math.min(rows, vim.o.lines - 1 - info.winrow)
  local cw, ch = renderer.cell_size()
  -- a cell's size in pixels, whole so rows stack exactly
  local cpx, rpx = math.floor(cw * scale + 0.5), math.floor(ch * scale + 0.5)
  local all, across = cols, util.fraction(config.position[1])
  local notes_cols = notes.margin(st, cols, rows, cpx, rpx)
  cols = all - math.floor(notes_cols * math.min(2, 1 / (1 - across)))
  -- comments go left of the page too when it leaves room for them there
  local sides = math.min(math.floor((all - cols) * across), all - notes_cols - cols) >= notes_cols
    and { 'left', 'right' } or { 'right' }
  local links = notes_cols > 0 and { cols = notes_cols, sides = sides } or nil
  if cols < 1 or rows < 1 then
    return
  end
  vim.fn.mkdir(renderer.cache, 'p')
  local png = string.format('%s/%d-%d.png', renderer.cache, vim.fn.getpid(), win)
  -- the gap between pages: the window's background
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  local stack = V.continuous(st) and {
    continuous = true, gap = math.floor(config.gap * rpx + 0.5), bg = string.format('#%06x', bg or 0),
  } or {}
  shown[win] = nil
  renderer.request(vim.tbl_extend('force', {
    id = win, file = st.file, page = st.page, zoom = st.zoom,
    x = st.x, y = st.y, out = png, width = cols * cpx, height = rows * rpx, select = V.selected(st),
    cursor = st.cursor,
    links = links and vim.tbl_extend('force', links, { row = rpx }),
  }, stack), function(r)
    if r.error then
      return vim.notify('pdf.nvim: ' .. r.error, vim.log.levels.ERROR)
    end
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local now = vim.b[buf].pdf
    now.commented, now.pw, now.ph = r.commented, r.pw, r.ph
    if notes.margin(now, all, rows, cpx, rpx) ~= notes_cols then
      -- the first comment, the last gone, or the page's size now known: the
      -- comments' room changes
      vim.b[buf].pdf = now
      return draw(win, true, scale)
    end
    -- what the renderer kept on the page, unless the state moved on meanwhile
    if now.page == st.page and now.x == st.x and now.y == st.y and now.zoom == st.zoom then
      now.page, now.x, now.y, now.zoom = r.page, r.x, r.y, r.zoom
    end
    now.count, now.mx, now.my, now.vw, now.vh, now.notes = r.count, r.mx, r.my, r.vw, r.vh, r.notes
    now.selected = r.selected
    vim.b[buf].pdf = now
    local w = math.min(cols, math.ceil(r.iw / cpx))
    local h = math.min(rows, math.ceil(r.ih / rpx))
    local box = {
      row = info.winrow + math.floor((rows - h) * util.fraction(config.position[2])),
      col = info.wincol + info.textoff + math.min(math.floor((all - w) * across), all - notes_cols - w),
      w = w,
      h = h,
    }
    if vim.api.nvim_get_current_buf() == buf then
      status(now)
    end
    shown[win] = {
      file = st.file, page = r.page, scale = r.scale, px = r.px, py = r.py, pxh = r.pxh, tops = r.tops,
      iw = r.iw, rows = rows, cpx = cpx, rpx = rpx, box = box, png = png, select = V.selected(st),
      cursor = st.cursor,
      margin = notes_cols, pages = {}, stack = stack,
      links = links and vim.tbl_extend('force', links, { row = rpx }),
      -- only a sharp frame filling the height of a window as wide as the
      -- screen scrolls by rows: whole lines move
      rolls = scale == config.scale and h == rows and r.ih == rows * rpx
        and info.wincol == 1 and info.width == vim.o.columns,
    }
    for _, g in ipairs(r.pages) do
      shown[win].pages[g.page] = g
    end
    notes.draw(win, shown[win])
    if clear or not vim.deep_equal(vim.w[win].pdf_box, box) then
      vim.w[win].pdf_box = box
      vim.cmd('mode')
      vim.schedule(function() renderer.send(png, box) end)
    else
      renderer.send(png, box)
    end
  end)
end

local sharp = assert(vim.uv.new_timer())

-- redraw(clear, fast): draw every window's page; fast draws it at the
-- scrolling scale now and sharp once it has stopped for a moment.
function V.redraw(clear, fast)
  vim.schedule(function()
    local function all(c, scale)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        draw(win, c, scale)
      end
    end
    sharp:stop()
    if fast and config.scale_scrolling < config.scale then
      all(clear, config.scale_scrolling)
      sharp:start(config.sharp_after, 0, vim.schedule_wrap(function() all(false, config.scale) end))
    else
      all(clear, config.scale)
    end
  end)
end

-- update(f, fast): change the current buffer's state with f, then draw it.
function V.update(f, fast)
  local st = vim.b.pdf
  f(st)
  st.page = math.max(0, math.min(st.page, (st.count or 1) - 1))
  vim.b.pdf = st
  V.redraw(false, fast)
end

-- go(n): show page n (1-based) of the current buffer, from its top.
function V.go(n)
  V.update(function(st)
    st.page, st.y = n - 1, 0
  end)
end

-- roll(sh, d): the escapes that move sh's rows d up (down when d < 0), image
-- and all. Whole lines: iTerm2 loses the images in cells it moves inside
-- left and right margins.
local function roll(sh, d)
  local b = sh.box
  return table.concat({
    string.format('\027[%d;%dr', b.row, b.row + b.h - 1),
    string.format('\027[%d;%dH', b.row, b.col),
    d > 0 and string.format('\027[%dS', d) or string.format('\027[%dT', -d),
    '\027[r',
  })
end

-- pump(win): move win's image toward its target, a strip of rows at a time.
local function pump(win)
  local sh = shown[win]
  if not sh or sh.busy or not sh.target or sh.target == sh.py then
    return
  end
  local d = (sh.target - sh.py) / sh.rpx
  if d ~= math.floor(d) or math.abs(d) >= sh.rows then
    -- not whole rows, or more than the window: all of it again
    return draw(win, false, config.scale)
  end
  sh.busy = true
  local py = d > 0 and sh.py + sh.rows * sh.rpx or sh.target
  local h = math.abs(d) * sh.rpx
  renderer.request(vim.tbl_extend('force', {
    id = win, file = sh.file, page = sh.page, scale = sh.scale,
    px = sh.px, py = py, width = sh.iw, height = h, out = sh.png, select = sh.select, cursor = sh.cursor,
    links = sh.links,
  }, sh.stack), function(r)
    if shown[win] ~= sh then
      return
    end
    sh.busy = false
    if r.error or r.py ~= py or r.ih ~= h or r.iw ~= sh.iw then
      return draw(win, false, config.scale)
    end
    -- the comments' text moves with the lines too, where nvim does not know:
    -- gone from the screen first, to draw it again where it goes
    notes.clear(win)
    vim.api.nvim__redraw({ flush = true })
    local b = sh.box
    renderer.send(sh.png, {
      row = d > 0 and b.row + b.h - d or b.row, col = b.col, w = b.w, h = math.abs(d),
    }, roll(sh, d))
    sh.py = sh.py + d * sh.rpx
    for _, g in ipairs(r.pages) do
      sh.pages[g.page] = g
    end
    notes.draw(win, sh)
    if vim.api.nvim_get_current_win() == win then
      status(vim.b.pdf)
    end
    pump(win)
  end)
end

-- roll_to(dy, step): scroll the current window by rows if it can, true if so.
local function roll_to(dy, step)
  local win = vim.api.nvim_get_current_win()
  local sh, st = shown[win], vim.b.pdf
  if not (config.smooth and sh and sh.rolls and sh.page == st.page) then
    return false
  end
  local from = sh.target or sh.py
  local last = sh.pxh - sh.rows * sh.rpx
  if (dy > 0 and from >= last) or (dy < 0 and from <= 0) then
    return false -- on to another page
  end
  local rows = math.max(1, math.floor(math.abs(step) * sh.rows + 0.5))
  sh.target = math.max(0, math.min(from + dy * rows * sh.rpx, last))
  sh.page, st.y = V.page_at(sh, sh.target)
  if st.page ~= sh.page then
    local g = sh.pages[sh.page]
    st.page, st.notes = sh.page, g and #g.marks or st.notes
  end
  vim.b.pdf = st
  pump(win)
  return true
end

-- scroll(dx, dy, step): move by dx, dy steps of step of the window; past the
-- bottom or top of the page, on into the next or previous one.
function V.scroll(dx, dy, step)
  if dx == 0 and dy ~= 0 and roll_to(dy, step) then
    return
  end
  V.update(function(st)
    st.x = st.x + dx * step * (st.vw or 0)
    if V.continuous(st) then
      -- the renderer keeps it in the document
      st.y = math.min(st.y + dy * step * (st.vh or 0), st.my or 0)
    elseif dy > 0 and st.y >= (st.my or 0) and st.page + 1 < (st.count or 1) then
      st.page, st.y = st.page + 1, 0
    elseif dy < 0 and st.y <= 0 and st.page > 0 then
      st.page, st.y = st.page - 1, 1e9
    else
      st.y = math.max(0, math.min(st.y + dy * step * (st.vh or 0), st.my or 0))
    end
    st.x = math.max(0, math.min(st.x, st.mx or 0))
  end, not (config.smooth and dx == 0)) -- sharp, to scroll by rows on from it
end

-- zoom(by): zoom by a factor, keeping the middle of the window where it is;
-- by nil fits the whole page.
function V.zoom(by)
  V.update(function(st)
    local cur = tonumber(st.zoom) or 1
    local z = by and math.max(1, cur * by) or 1
    local r = cur / z
    st.x = st.x + (st.vw or 0) * (1 - r) / 2
    st.y = st.y + (st.vh or 0) * (1 - r) / 2
    st.zoom = z
  end)
end

-- fit_width(): zoom so the page fills the window's width.
function V.fit_width()
  V.update(function(st)
    st.zoom, st.x = 'width', 0
  end)
end

-- margin(): show or hide the comments' text beside the page.
function V.margin()
  V.update(function(st)
    st.margin = st.margin == false
  end)
end

-- in_view(win, c): whether the window shows c, a spot on its pages.
function V.in_view(win, c)
  local sh = shown[win]
  if not (sh and c) then
    return c ~= nil
  end
  if not sh.tops and c.page ~= sh.page then
    return false
  end
  local y = (sh.tops and sh.tops[c.page + 1] or 0) + c.y * sh.scale
  local x = c.x * sh.scale
  local top = sh.target or sh.py
  return y >= top and y < top + sh.rows * sh.rpx and x >= sh.px and x < sh.px + sh.iw
end

-- screen_row(win, which): the spot at the top (H), middle (M) or bottom (L)
-- of what the window shows, on its left.
function V.screen_row(win, which)
  local sh = shown[win]
  if not sh then
    return
  end
  local b = sh.box
  local row = which == 'H' and 0 or which == 'M' and math.floor(b.h / 2) or b.h - 1
  local page, y = V.page_at(sh, sh.py + (row + 0.5) * sh.rpx)
  return { page = page, x = sh.px / sh.scale, y = y }
end

return V
