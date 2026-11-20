-- What each window shows of its PDF: drawing it, scrolling and zooming it.
local config = require('pdf.config')
local notes = require('pdf.notes')
local renderer = require('pdf.renderer')
local terminal = require('pdf.terminal')
local util = require('pdf.util')
local V = {}

-- The last search (/ or ?), for n and N: { pattern, ignore (case), back };
-- on while its matches show, until <Esc>, as 'hlsearch' shows them.
V.search = nil
V.search_on = false
-- notice: a message ({ chunks } as util.say takes) shown instead of the
-- status until the next key, so a redraw ending later keeps it
local notice
local notice_ns = vim.api.nvim_create_namespace('pdf.notice')

function V.notice(chunks)
  notice = chunks
  util.say(chunks)
  vim.on_key(function()
    notice = nil
    vim.on_key(nil, notice_ns)
  end, notice_ns)
end

-- searching(): the search whose matches show, as render's look takes it.
local function searching()
  return V.search_on and vim.o.hlsearch and { pattern = V.search.pattern, ignore = V.search.ignore } or nil
end

local function status(st)
  if notice then
    return util.say(notice)
  end
  if st.selected then
    local t = vim.fn.strcharpart(st.selected, 0, 50)
    return util.say({ { string.format('selected "%s%s": c comments on it, y copies it, <Esc> lets go', t,
      t == st.selected and '' or '…') } })
  end
  local zoom = math.abs(st.zoom - 1) < 0.01 and '' or string.format('  %d%%', st.zoom * 100)
  local notes = (st.notes or 0) > 0 and string.format('  %d comment%s', st.notes, st.notes > 1 and 's' or '') or ''
  local search = V.search_on and '  ' .. (V.search.back and '?' or '/') .. V.search.pattern or ''
  util.say({ { string.format('page %d/%d%s%s%s', st.page + 1, st.count or 0, zoom, notes, search) } })
end

-- selected(st): the text selected, as render takes it: from where v (or V,
-- whole lines) started to the cursor.
function V.selected(st)
  local v, c = st.visual, st.cursor
  return v and c and { page = v.page, a = { x = v.x, y = v.y }, b = { x = c.x, y = c.y }, lines = v.lines } or nil
end

-- colors(name): highlight group name's { fg, bg } as "#rrggbb", reversed
-- when it says so; either nil when it has none.
local function colors(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  local function hex(c)
    return c and string.format('#%06x', c)
  end
  local fg, bg = hex(h.fg), hex(h.bg)
  if h.reverse then
    fg, bg = bg, fg
  end
  return { fg = fg, bg = bg }
end

-- look(st): how the selection, the cursor, the search's matches and the
-- flash look on the page, as render takes it: as Vim's own, in the Visual,
-- Cursor, Search and config.synctex.flash highlights (or Normal's colours,
-- reversed, where they have none),
-- the cursor's shape as 'guicursor' has it for Normal mode (Visual's while
-- selecting).
function V.look(st)
  local normal = colors('Normal')
  normal.fg, normal.bg = normal.fg or '#ffffff', normal.bg or '#000000'
  local visual = colors('Visual')
  local mode = st.visual and 'v' or 'n'
  local cursor = { shape = 'block' }
  local group = 'Cursor'
  for _, entry in ipairs(vim.split(vim.o.guicursor, ',', { trimempty = true })) do
    local modes, arg = entry:match('^([^:]+):(.*)$')
    if modes and vim.list_contains(vim.split(modes, '-'), mode) then
      for _, part in ipairs(vim.split(arg, '-')) do
        local shape, size = part:match('^(%a+)(%d*)$')
        if shape == 'block' or shape == 'ver' or shape == 'hor' then
          cursor.shape, cursor.size = shape, tonumber(size)
        elseif part:match('^%u') then
          group = part:match('^[^/]+')
        end
      end
    end
  end
  local c = colors(group)
  cursor.fg, cursor.bg = c.bg and c.fg or normal.bg, c.bg or normal.fg
  local search = searching()
  if search then
    local c = colors('Search')
    search.fg, search.bg = c.fg or normal.fg, c.bg or normal.fg
  end
  local flash = colors(config.synctex.flash)
  return {
    visual = { fg = visual.fg or normal.fg, bg = visual.bg or normal.fg },
    cursor = cursor,
    search = search,
    flash = { fg = flash.fg or normal.bg, bg = flash.bg or normal.fg },
  }
end

-- continuous(st): whether st's pages show stacked, one on from the other:
-- at every zoom, the whole page's too, so scrolling never turns into paging.
function V.continuous(st)
  return config.continuous
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

-- at(st): where st's view is, and the matches it shows, to tell whether a
-- frame still shows it.
local function at(st)
  return { page = st.page, x = st.x, y = st.y, zoom = st.zoom, search = searching() }
end

-- Drawing a window's page, at one scale (config.scale) always, so it never
-- changes how sharp or how big it shows:
--   layout(win, st): where the page goes in the window, in cells and pixels;
--   draw(win, clear): a whole frame, rendered and drawn over the last;
--   then, on a frame, one job at a time (see work): mark draws only the rows
--   the cursor and the selection take and took; roll moves the rows a step
--   of a scroll and draws only those that come in.

-- layout(win, st): where st's page goes in win, or nil without room:
-- { info (getwininfo's), all (the text's columns), cols, rows (the page's
-- most), cpx, rpx (a cell's pixels), across (config.position's), margin (the
-- comments' columns), links, stack (as render takes them), png (the image's
-- file) }.
local function layout(win, st)
  local info = vim.fn.getwininfo(win)[1]
  -- the last screen row scrolls the terminal
  local all, rows = info.width - info.textoff, math.min(info.height, vim.o.lines - 1 - info.winrow)
  local cw, ch = terminal.cell_size()
  -- a cell's size in pixels: a row's whole, so rows stack exactly; a
  -- column's as the terminal's are shaped, not rounded, or the image, which
  -- the terminal stretches to its cells, is shaped by the rounding
  local cpx, rpx = cw * config.scale, math.floor(ch * config.scale + 0.5)
  -- the page sits where position says in all of the window, its comments'
  -- text beside it: the page gets what leaves room for that
  local across = util.fraction(config.position[1])
  local margin = notes.margin(st, all, rows, cpx, rpx)
  local cols = all - math.floor(margin * math.min(2, 1 / (1 - across)))
  if cols < 1 or rows < 1 then
    return
  end
  -- comments go left of the page too when it leaves room for them there
  local sides = math.min(math.floor((all - cols) * across), all - margin - cols) >= margin
    and { 'left', 'right' } or { 'right' }
  -- the gap between pages: the window's background
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  vim.fn.mkdir(renderer.cache, 'p')
  return {
    info = info, all = all, cols = cols, rows = rows, cpx = cpx, rpx = rpx, across = across, margin = margin,
    links = margin > 0 and {
      cols = margin, sides = sides, lines = config.notes_lines > 0 and config.notes_lines or nil, row = rpx,
    } or nil,
    stack = V.continuous(st) and {
      continuous = true, gap = math.floor(config.gap * rpx + 0.5), bg = string.format('#%06x', bg or 0),
    } or {},
    png = string.format('%s/%d-%d.png', renderer.cache, vim.fn.getpid(), win),
  }
end

-- box(lay, iw, ih): the cells an image iw x ih pixels takes in lay's window,
-- { row, col, w, h }, on the screen.
local function box(lay, iw, ih)
  local w, h = math.min(lay.cols, math.ceil(iw / lay.cpx)), math.min(lay.rows, math.ceil(ih / lay.rpx))
  return {
    row = lay.info.winrow + math.floor((lay.rows - h) * util.fraction(config.position[2])),
    col = lay.info.wincol + lay.info.textoff + math.min(math.floor((lay.all - w) * lay.across), lay.all - lay.margin - w),
    w = w,
    h = h,
  }
end

-- What each window shows, from its last whole frame on (draw): { file,
-- page (at its top), scale, px, py (its offset in pixels), target (the py
-- its scroll goes to, py when still), share (of the way there each step),
-- pxh, tops, iw, rows, cpx, rpx, box, png, select, cursor, flash, look (as it was
-- rendered), margin, links, stack, pages (each shown's {page, top, marks}),
-- marked (the pixel rows marks take), at (the view it shows or goes to, as
-- at() has it), full (it fills the window's height), busy (a job out),
-- remark (marks to draw again) }.
local shown = {}
V.shown = shown

-- draw(win, clear): render win's page and draw it, whole. nvim's own redraw
-- (:mode) wipes the old image first when clear is set or the image's cells
-- change; otherwise the new image covers the old one, without a flicker.
local function draw(win, clear)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local st = vim.b[buf].pdf
  local lay = st and layout(win, st)
  if not lay then
    return
  end
  shown[win] = nil
  local select, look = V.selected(st), V.look(st)
  renderer.request(vim.tbl_extend('force', {
    id = win, file = st.file, page = st.page, zoom = st.zoom, x = st.x, y = st.y, out = lay.png,
    width = math.floor(lay.cols * lay.cpx), height = lay.rows * lay.rpx,
    select = select, cursor = st.cursor, flash = st.flash, look = look, links = lay.links,
  }, lay.stack), function(r)
    if r.error then
      return vim.notify('pdf.nvim: ' .. r.error, vim.log.levels.ERROR)
    end
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    local now = vim.b[buf].pdf
    now.commented, now.pw, now.ph = r.commented, r.pw, r.ph
    if notes.margin(now, lay.all, lay.rows, lay.cpx, lay.rpx) ~= lay.margin then
      -- the first comment, the last gone, or the page's size now known: the
      -- comments' room changes
      vim.b[buf].pdf = now
      return draw(win, true)
    end
    -- what the renderer kept on the page, unless the state moved on meanwhile
    local still = now.page == st.page and now.x == st.x and now.y == st.y and now.zoom == st.zoom
    if still then
      now.page, now.x, now.y, now.zoom = r.page, r.x, r.y, r.zoom
    end
    now.count, now.mx, now.my, now.vw, now.vh, now.notes = r.count, r.mx, r.my, r.vw, r.vh, r.notes
    now.selected = r.selected
    vim.b[buf].pdf = now
    local b = box(lay, r.iw, r.ih)
    if vim.api.nvim_get_current_buf() == buf then
      status(now)
    end
    local sh = {
      file = st.file, page = r.page, scale = r.scale, px = r.px, py = r.py, target = r.py, share = 1,
      pxh = r.pxh, tops = r.tops, iw = r.iw, rows = lay.rows, cpx = lay.cpx, rpx = lay.rpx, box = b, png = lay.png,
      select = select, cursor = st.cursor, flash = st.flash, look = look, margin = lay.margin, links = lay.links, stack = lay.stack,
      pages = {}, marked = r.marked,
      -- (moved on: another frame comes)
      at = still and at(now) or nil,
      full = b.h == lay.rows and r.ih == lay.rows * lay.rpx,
    }
    for _, g in ipairs(r.pages) do
      sh.pages[g.page] = g
    end
    shown[win] = sh
    notes.draw(win, sh)
    if clear or not vim.deep_equal(vim.w[win].pdf_box, b) then
      vim.w[win].pdf_box = b
      -- the screen wiped and the page drawn in one frame, so the page never
      -- shows gone in between
      terminal.frame(function()
        vim.cmd('mode')
        vim.api.nvim__redraw({ flush = true, valid = false })
        terminal.draw(win, lay.png, b)
      end)
    else
      terminal.draw(win, lay.png, b)
    end
  end)
end

-- redraw(clear): draw every window's page, whole.
function V.redraw(clear)
  vim.schedule(function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      draw(win, clear)
    end
  end)
end

-- update(f): change the current buffer's state with f, then draw it.
function V.update(f)
  local st = vim.b.pdf
  f(st)
  st.page = math.max(0, math.min(st.page, (st.count or 1) - 1))
  vim.b.pdf = st
  V.redraw(false)
end

-- go(n): show page n (1-based) of the current buffer, from its top.
function V.go(n)
  V.update(function(st)
    st.page, st.y = n - 1, 0
  end)
end

-- beside(win, sh): the other windows in the rows sh's image takes, which
-- its rolls move too: to send again after. nil when its rows cannot roll:
-- the image short of the window's height, a window over its comments, or
-- another window's page in its rows, which would move too.
local function beside(win, sh)
  if not (config.smooth and sh.full) or notes.covered(win) then
    return
  end
  local top, bottom, list = sh.box.row, sh.box.row + sh.box.h - 1, {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local i = vim.fn.getwininfo(w)[1]
    -- its rows from its window bar to its status line (or the row past it)
    if w ~= win and i.winrow - i.winbar <= bottom and i.winrow + i.height >= top then
      if shown[w] then
        return
      end
      list[#list + 1] = w
    end
  end
  return list
end

-- job(win, sh, fields, done): render what sh shows, with fields, the only
-- request out for its window until done(r) has the reply; a whole frame
-- instead when it fails.
local work
local function job(win, sh, fields, done)
  sh.busy = true
  renderer.request(vim.tbl_extend('force', {
    id = win, file = sh.file, page = sh.page, scale = sh.scale, px = sh.px, py = sh.py,
    width = sh.iw, height = sh.rows * sh.rpx, out = sh.png,
    select = sh.select, cursor = sh.cursor, flash = sh.flash, look = sh.look, links = sh.links,
  }, sh.stack, fields), function(r)
    if shown[win] ~= sh then
      return -- drawn whole since
    end
    sh.busy = false
    if r.error then
      return draw(win)
    end
    done(r)
    work(win)
  end)
end

-- mark(win, sh): draw where win's cursor, selection and flash are now: of its
-- view, only the rows they take and took, a few rows to render and send.
local function mark(win, sh)
  sh.remark = false
  local buf = vim.api.nvim_win_get_buf(win)
  local st = vim.b[buf].pdf
  local select, look = V.selected(st), V.look(st)
  local fields = { select = select, cursor = st.cursor, flash = st.flash, look = look }
  job(win, sh, vim.tbl_extend('force', fields, { strip = { row = sh.rpx, keep = sh.marked } }),
    function(r)
      sh.select, sh.cursor, sh.flash, sh.look, sh.marked = select, st.cursor, st.flash, look, r.marked
      local now = vim.b[buf].pdf
      now.selected = r.selected
      vim.b[buf].pdf = now
      if r.strip then
        local b = sh.box
        terminal.draw(win, sh.png, { row = b.row + r.strip[1], col = b.col, w = b.w, h = r.strip[2] - r.strip[1] }, b)
      end
      if vim.api.nvim_get_current_win() == win then
        status(now)
      end
    end)
end

-- roll(win, sh): a step of sh's scroll: the terminal moves its rows, image
-- and all, and only the rows that come in are rendered and drawn. Each step
-- a share of the way left (sh.share), at least a row, at most the window's
-- less one, as all of it costs as much as a whole frame.
local function roll(win, sh)
  local d = (sh.target - sh.py) / sh.rpx
  if d ~= math.floor(d) or not beside(win, sh) then
    return draw(win)
  end
  local n = math.min(math.max(1, math.ceil(math.abs(d) * sh.share)), sh.rows - 1)
  d = d > 0 and math.min(d, n) or math.max(d, -n)
  local py, h = d > 0 and sh.py + sh.rows * sh.rpx or sh.py + d * sh.rpx, math.abs(d) * sh.rpx
  job(win, sh, { py = py, height = h }, function(r)
    local wins = beside(win, sh)
    if r.py ~= py or r.ih ~= h or r.iw ~= sh.iw or not wins then
      return draw(win)
    end
    -- the comments' text moves with the rows too, where nvim does not know:
    -- gone first, to draw it again where it goes, all in one frame so it
    -- never shows gone
    terminal.frame(function()
      notes.clear(win)
      vim.api.nvim__redraw({ flush = true })
      local b = sh.box
      terminal.roll(win, b, d, wins)
      terminal.draw(win, sh.png, { row = d > 0 and b.row + b.h - d or b.row, col = b.col, w = b.w, h = math.abs(d) }, b)
      sh.py = sh.py + d * sh.rpx
      for _, g in ipairs(r.pages) do
        sh.pages[g.page] = g
      end
      notes.draw(win, sh)
    end)
    if vim.api.nvim_get_current_win() == win then
      status(vim.b.pdf)
    end
  end)
end

-- work(win): win's frame's next job, once none is out: its marks first,
-- then its scroll's next step, config.frame ms on.
work = function(win)
  local sh = shown[win]
  if not sh or sh.busy then
    return
  end
  if sh.remark then
    return mark(win, sh)
  end
  if sh.target ~= sh.py then
    sh.busy = true
    vim.defer_fn(function()
      if shown[win] == sh then
        sh.busy = false
        roll(win, sh)
      end
    end, config.frame)
  end
end

-- mark(win): show where win's cursor, selection and flash are now; a whole frame
-- when it shows another view now.
function V.mark(win)
  win = win or vim.api.nvim_get_current_win()
  local sh, st = shown[win], vim.b[vim.api.nvim_win_get_buf(win)].pdf
  if not (sh and st and vim.deep_equal(sh.at, at(st))) then
    return V.redraw()
  end
  sh.remark = true
  work(win)
end

-- roll_to(dy, step, share): scroll the current window dy steps of step of
-- it by rolling its rows, each step share of the way left; false when it
-- cannot (see beside), or the scroll goes on past what it shows.
local function roll_to(dy, step, share)
  local win = vim.api.nvim_get_current_win()
  local sh, st = shown[win], vim.b.pdf
  if not (sh and vim.deep_equal(sh.at, at(st)) and beside(win, sh)) then
    return false
  end
  local last = sh.pxh - sh.rows * sh.rpx
  if (dy > 0 and sh.target >= last) or (dy < 0 and sh.target <= 0) then
    return false -- on to another page
  end
  local rows = math.max(1, math.floor(math.abs(step) * sh.rows + 0.5))
  sh.target, sh.share = math.max(0, math.min(sh.target + dy * rows * sh.rpx, last)), share
  sh.page, st.y = V.page_at(sh, sh.target)
  if st.page ~= sh.page then
    local g = sh.pages[sh.page]
    st.page, st.notes = sh.page, g and #g.marks or st.notes
  end
  vim.b.pdf = st
  sh.at = at(st)
  work(win)
  return true
end

-- scroll(dx, dy, step, share): move by dx, dy steps of step of the window,
-- share of the way left each frame (1, nil: at once); past the bottom or top
-- of the page, on into the next or previous one.
function V.scroll(dx, dy, step, share)
  if dx == 0 and dy ~= 0 and roll_to(dy, step, share or 1) then
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
  end)
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
