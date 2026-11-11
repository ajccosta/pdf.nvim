-- pdf.nvim: `nvim file.pdf` shows its pages, drawn in the window with iTerm2's
-- inline image protocol. PyMuPDF renders each page to a PNG, in a process kept
-- running (python/render.py).
local M = {}

M.config = {
  python = 'python3', -- one with PyMuPDF (`pip install pymupdf`)
  cell = { 9, 18 }, -- cell size in pixels, when the terminal does not say
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
  scroll = 0.2, -- a scroll key moves this much of the window
  wheel = 0.05, -- and a wheel tick this much
  zoom = 1.25, -- a zoom in or out multiplies by this
  comments_width = 40, -- the comments list's window, in columns
  notes_width = 40, -- columns each side of the page for its comments; 0: none
  notes_min_width = 12, -- zoomed in, fewer than this left beside the page: none
  -- new comments' colour: a name from colors or "#rrggbb"; see :PdfColor
  color = 'blue',
  colors = {
    yellow = '#ffe873', orange = '#fab387', red = '#f38ba8', pink = '#f5c2e7',
    purple = '#cba6f7', blue = '#89b4fa', teal = '#94e2d5', green = '#a6e3a1',
  },
  keys = {
    next = { 'n', '<Space>', '<PageDown>' },
    prev = { 'p', '<BS>', '<PageUp>' },
    first = { 'gg', '<Home>' },
    last = { 'G', '<End>' },
    down = { 'j', '<Down>' },
    up = { 'k', '<Up>' },
    left = { 'h', '<Left>' },
    right = { 'l', '<Right>' },
    wheel_down = { '<ScrollWheelDown>' },
    wheel_up = { '<ScrollWheelUp>' },
    wheel_left = { '<ScrollWheelLeft>' },
    wheel_right = { '<ScrollWheelRight>' },
    zoom_in = { '+', '=' },
    zoom_out = { '-' },
    fit = { '0' },
    fit_width = { 'w' },
    point = { '<LeftMouse>' },
    drag = { '<LeftDrag>' },
    release = { '<LeftRelease>' },
    clear = { '<Esc>' },
    comment = { 'c' },
    comments = { 'C' },
    margin = { 'm' },
  },
  -- in the comments list
  list_keys = {
    jump = { '<CR>' },
  },
}

-- The positions by name, as fractions of the room left around the page.
M.positions = { left = 0, top = 0, center = 0.5, right = 1, bottom = 1 }

local function fraction(p)
  return math.max(0, math.min(1, tonumber(p) or M.positions[p] or 0.5))
end

-- The settings a command changes, remembered across sessions: they win over
-- setup's, which are the defaults until one is chosen.
M.remembered = { 'position', 'color' }
local state_file = vim.fn.stdpath('state') .. '/pdf.nvim.json'

local function saved()
  local f = io.open(state_file, 'r')
  if not f then
    return {}
  end
  local ok, t = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(t) == 'table' and t or {}
end

-- remember(name, value): set config[name] for this and later sessions.
local function remember(name, value)
  M.config[name] = value
  local t = saved()
  t[name] = value
  vim.fn.mkdir(vim.fn.fnamemodify(state_file, ':h'), 'p')
  local f = io.open(state_file, 'w')
  if f then
    f:write(vim.json.encode(t))
    f:close()
  end
end

local function apply_saved()
  local t = saved()
  for _, name in ipairs(M.remembered) do
    if t[name] ~= nil then
      M.config[name] = t[name]
    end
  end
end

-- A paste into a PDF's window (a middle click, a PDF dropped on it): a PDF's
-- path opens that PDF, anything else is dropped, as the page takes no text.
-- iTerm pastes a copy of the page's image when a click drags it a little.
local paste, pasted = vim.paste, ''
vim.paste = function(lines, phase)
  if not vim.b.pdf then
    return paste(lines, phase)
  end
  pasted = (phase == -1 or phase == 1) and '' or pasted
  pasted = pasted .. table.concat(lines, '\n')
  if phase == -1 or phase == 3 then
    local path = vim.trim(pasted):gsub([[^(['"])(.*)%1$]], '%2'):gsub('\\(.)', '%1')
    if path:lower():match('%.pdf$') and vim.fn.filereadable(vim.fn.expand(path)) == 1 then
      vim.cmd.edit(vim.fn.fnameescape(vim.fn.expand(path)))
    end
  end
  return true
end

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local cache = vim.fn.stdpath('cache') .. '/pdf.nvim'

-- The terminal's cell size in pixels, from TIOCGWINSZ on /dev/tty.
local function cell_size()
  local ok, ffi = pcall(require, 'ffi')
  if ok then
    pcall(ffi.cdef, [[
      struct pdf_winsize { unsigned short row, col, xpixel, ypixel; };
      int open(const char *path, int flags);
      int close(int fd);
      int ioctl(int fd, unsigned long req, ...);
    ]])
    local fd = ffi.C.open('/dev/tty', 0)
    if fd >= 0 then
      local ws = ffi.new('struct pdf_winsize')
      local req = vim.fn.has('mac') == 1 and 0x40087468 or 0x5413
      local r = ffi.C.ioctl(fd, req, ws)
      ffi.C.close(fd)
      if r == 0 and ws.xpixel > 0 and ws.col > 0 then
        return ws.xpixel / ws.col, ws.ypixel / ws.row
      end
    end
  end
  return M.config.cell[1], M.config.cell[2]
end

-- The renderer: one request at a time per window, and of those that come
-- while one is out only the latest, so a fast scroll skips frames instead of
-- falling behind.
local renderer = { proc = nil, out = '', busy = {}, pending = {}, callbacks = {} }

local send_request

local function on_reply(line)
  local ok, r = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok then
    return
  end
  local win = r.id
  local cb = renderer.callbacks[win]
  renderer.busy[win], renderer.callbacks[win] = nil, nil
  if cb then
    cb(r)
  end
  -- one at a time per window: the next waiting, unless cb sent a later one
  local next = renderer.pending[win]
  renderer.pending[win] = nil
  if next and not renderer.busy[win] then
    send_request(next[1], next[2])
  end
end

local function start()
  renderer.proc = vim.system({ M.config.python, '-u', root .. '/python/render.py' }, {
    stdin = true,
    stdout = vim.schedule_wrap(function(_, data)
      if not data then
        return
      end
      renderer.out = renderer.out .. data
      for line in renderer.out:gmatch('([^\n]*)\n') do
        on_reply(line)
      end
      renderer.out = renderer.out:match('[^\n]*$')
    end),
    stderr = vim.schedule_wrap(function(_, data)
      if data and data ~= '' then
        vim.notify('pdf.nvim: ' .. vim.trim(data), vim.log.levels.ERROR)
      end
    end),
  }, vim.schedule_wrap(function()
    renderer.proc, renderer.busy, renderer.pending, renderer.callbacks = nil, {}, {}, {}
  end))
end

send_request = function(req, cb)
  if not renderer.proc then
    start()
  end
  renderer.busy[req.id], renderer.callbacks[req.id] = true, cb
  renderer.proc:write(vim.json.encode(req) .. '\n')
end

local function request(req, cb)
  if renderer.busy[req.id] then
    renderer.pending[req.id] = { req, cb }
  else
    send_request(req, cb)
  end
end

-- op(req, cb): one of the renderer's other ops (comments, apply); each its
-- own, none dropped for a later one.
local ops = 0
local function op(req, cb)
  ops = ops + 1
  req.id = 'op' .. ops
  send_request(req, function(r)
    if r.error then
      return vim.notify('pdf.nvim: ' .. r.error, vim.log.levels.ERROR)
    end
    cb(r)
  end)
end

-- send(png, box, before): draw png in box's cells, after the escapes before.
local function send(png, box, before)
  local f = io.open(png, 'rb')
  if not f then
    return
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  vim.api.nvim_ui_send(string.format(
    '\0277%s\027[%d;%dH\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1;doNotMoveCursor=1:%s\007\0278',
    before or '', box.row, box.col, box.w, box.h, data))
end

local function status(st)
  if st.selected then
    local t = vim.fn.strcharpart(st.selected, 0, 50)
    return vim.api.nvim_echo({ { string.format('selected "%s%s": c comments on it, <Esc> lets go', t,
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

-- selected(st): the text selected, as render takes it.
local function selected(st)
  local s = st.select
  return s and { page = s.page, a = s.a, b = s.b } or nil
end

-- continuous(st): whether st's pages show stacked, one on from the other.
local function continuous(st)
  return M.config.continuous and st.zoom ~= 1
end

-- page_at(sh, py): the page at sh's pixel row py, and where in it in points.
local function page_at(sh, py)
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

-- text(content): a comment's text as the list has it, its lines trimmed.
local function text(content)
  local lines = {}
  for _, l in ipairs(vim.split(content or '', '\n')) do
    if vim.trim(l) ~= '' then
      lines[#lines + 1] = vim.trim(l)
    end
  end
  return lines
end

-- margin(st, cols, rows, cpx, rpx): how many of a window's cols go to the
-- comments' text on each side of the page: none when hidden (`m`), the PDF
-- has none or the window is narrow; and zoomed in, only what the page leaves
-- (none under notes_min_width), so they never cover it. Fitting the width,
-- only what leaves the page taller than the window, so it scrolls by rows.
local function margin(st, cols, rows, cpx, rpx)
  local w = M.config.notes_width
  if st.margin == false or not st.commented or w <= 0 or cols - 2 * w < 20 then
    return 0
  end
  if not st.pw then
    return w
  end
  local k = math.min(2, 1 / (1 - fraction(M.config.position[1])))
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
  for n = w, M.config.notes_min_width, -1 do
    if fits(room(n)) then
      return n
    end
  end
  return 0
end

-- wrap(lines, width): lines broken at spaces to fit width columns.
local function wrap(lines, width)
  local out = {}
  for _, l in ipairs(lines) do
    local line = ''
    for word in l:gmatch('%S+') do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= '' then
          out[#out + 1], line = line, ''
        end
        out[#out + 1], word = vim.fn.strcharpart(word, 0, width), vim.fn.strcharpart(word, width)
      end
      if line ~= '' and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
        out[#out + 1], line = line, word
      else
        line = line == '' and word or line .. ' ' .. word
      end
    end
    out[#out + 1] = line
  end
  return out
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
function M.unnote(win)
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

-- notes(win): the comments on the pages win shows as text beside them, each on the row
-- of where it is (or below the one before on its side), a line in its colour
-- from there. Laid out as on the right, then mirrored for the left.
local function notes(win)
  local sh = shown[win]
  if not sh or not vim.api.nvim_win_is_valid(win) then
    return M.unnote(win)
  end
  sh.noted = { left = {}, right = {} }
  if sh.margin == 0 then
    return M.unnote(win)
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
      found[#found + 1] = vim.tbl_extend('force', m, { top = sh.pages[n].top })
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
      local lines = wrap(text(m.content), sh.margin - 2)
      for i, l in ipairs(lines) do
        put(side, t + i - 1, to + 1, l, 'PdfNote', m)
      end
      below[side] = t + #lines + 1
    end
  end
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
  local cw, ch = cell_size()
  -- a cell's size in pixels, whole so rows stack exactly
  local cpx, rpx = math.floor(cw * scale + 0.5), math.floor(ch * scale + 0.5)
  local all, across = cols, fraction(M.config.position[1])
  local notes_cols = margin(st, cols, rows, cpx, rpx)
  cols = all - math.floor(notes_cols * math.min(2, 1 / (1 - across)))
  -- comments go left of the page too when it leaves room for them there
  local sides = math.min(math.floor((all - cols) * across), all - notes_cols - cols) >= notes_cols
    and { 'left', 'right' } or { 'right' }
  local links = notes_cols > 0 and { cols = notes_cols, sides = sides } or nil
  if cols < 1 or rows < 1 then
    return
  end
  vim.fn.mkdir(cache, 'p')
  local png = string.format('%s/%d-%d.png', cache, vim.fn.getpid(), win)
  -- the gap between pages: the window's background
  local bg = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
  local stack = continuous(st) and {
    continuous = true, gap = math.floor(M.config.gap * rpx + 0.5), bg = string.format('#%06x', bg or 0),
  } or {}
  shown[win] = nil
  request(vim.tbl_extend('force', {
    id = win, file = st.file, page = st.page, zoom = st.zoom,
    x = st.x, y = st.y, out = png, width = cols * cpx, height = rows * rpx, select = selected(st),
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
    if margin(now, all, rows, cpx, rpx) ~= notes_cols then
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
      row = info.winrow + math.floor((rows - h) * fraction(M.config.position[2])),
      col = info.wincol + info.textoff + math.min(math.floor((all - w) * across), all - notes_cols - w),
      w = w,
      h = h,
    }
    if vim.api.nvim_get_current_buf() == buf then
      status(now)
    end
    shown[win] = {
      file = st.file, page = r.page, scale = r.scale, px = r.px, py = r.py, pxh = r.pxh, tops = r.tops,
      iw = r.iw, rows = rows, cpx = cpx, rpx = rpx, box = box, png = png, select = selected(st),
      margin = notes_cols, pages = {}, stack = stack,
      links = links and vim.tbl_extend('force', links, { row = rpx }),
      -- only a sharp frame filling the height of a window as wide as the
      -- screen scrolls by rows: whole lines move
      rolls = scale == M.config.scale and h == rows and r.ih == rows * rpx
        and info.wincol == 1 and info.width == vim.o.columns,
    }
    for _, g in ipairs(r.pages) do
      shown[win].pages[g.page] = g
    end
    notes(win)
    if clear or not vim.deep_equal(vim.w[win].pdf_box, box) then
      vim.w[win].pdf_box = box
      vim.cmd('mode')
      vim.schedule(function() send(png, box) end)
    else
      send(png, box)
    end
  end)
end

local sharp = assert(vim.uv.new_timer())

-- redraw(clear, fast): draw every window's page; fast draws it at the
-- scrolling scale now and sharp once it has stopped for a moment.
function M.redraw(clear, fast)
  vim.schedule(function()
    local function all(c, scale)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        draw(win, c, scale)
      end
    end
    sharp:stop()
    if fast and M.config.scale_scrolling < M.config.scale then
      all(clear, M.config.scale_scrolling)
      sharp:start(M.config.sharp_after, 0, vim.schedule_wrap(function() all(false, M.config.scale) end))
    else
      all(clear, M.config.scale)
    end
  end)
end

-- update(f, fast): change the current buffer's state with f, then draw it.
local function update(f, fast)
  local st = vim.b.pdf
  f(st)
  st.page = math.max(0, math.min(st.page, (st.count or 1) - 1))
  vim.b.pdf = st
  M.redraw(false, fast)
end

-- go(n): show page n (1-based) of the current buffer, from its top.
function M.go(n)
  update(function(st)
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
    return draw(win, false, M.config.scale)
  end
  sh.busy = true
  local py = d > 0 and sh.py + sh.rows * sh.rpx or sh.target
  local h = math.abs(d) * sh.rpx
  request(vim.tbl_extend('force', {
    id = win, file = sh.file, page = sh.page, scale = sh.scale,
    px = sh.px, py = py, width = sh.iw, height = h, out = sh.png, select = sh.select, links = sh.links,
  }, sh.stack), function(r)
    if shown[win] ~= sh then
      return
    end
    sh.busy = false
    if r.error or r.py ~= py or r.ih ~= h or r.iw ~= sh.iw then
      return draw(win, false, M.config.scale)
    end
    -- the comments' text moves with the lines too, where nvim does not know:
    -- gone from the screen first, to draw it again where it goes
    for _, f in pairs(sides[win] or {}) do
      vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(f), ns, 0, -1)
    end
    vim.api.nvim__redraw({ flush = true })
    local b = sh.box
    send(sh.png, {
      row = d > 0 and b.row + b.h - d or b.row, col = b.col, w = b.w, h = math.abs(d),
    }, roll(sh, d))
    sh.py = sh.py + d * sh.rpx
    for _, g in ipairs(r.pages) do
      sh.pages[g.page] = g
    end
    notes(win)
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
  if not (M.config.smooth and sh and sh.rolls and sh.page == st.page) then
    return false
  end
  local from = sh.target or sh.py
  local last = sh.pxh - sh.rows * sh.rpx
  if (dy > 0 and from >= last) or (dy < 0 and from <= 0) then
    return false -- on to another page
  end
  local rows = math.max(1, math.floor(math.abs(step) * sh.rows + 0.5))
  sh.target = math.max(0, math.min(from + dy * rows * sh.rpx, last))
  sh.page, st.y = page_at(sh, sh.target)
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
function M.scroll(dx, dy, step)
  if dx == 0 and dy ~= 0 and roll_to(dy, step) then
    return
  end
  update(function(st)
    st.x = st.x + dx * step * (st.vw or 0)
    if continuous(st) then
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
  end, not (M.config.smooth and dx == 0)) -- sharp, to scroll by rows on from it
end

-- zoom(by): zoom by a factor, keeping the middle of the window where it is;
-- by nil fits the whole page.
function M.zoom(by)
  update(function(st)
    local cur = tonumber(st.zoom) or 1
    local z = by and math.max(1, cur * by) or 1
    local r = cur / z
    st.x = st.x + (st.vw or 0) * (1 - r) / 2
    st.y = st.y + (st.vh or 0) * (1 - r) / 2
    st.zoom = z
  end)
end

-- fit_width(): zoom so the page fills the window's width.
function M.fit_width()
  update(function(st)
    st.zoom, st.x = 'width', 0
  end)
end

-- margin(): show or hide the comments' text beside the page.
function M.margin()
  update(function(st)
    st.margin = st.margin == false
  end)
end

-- Comments: the PDF's own notes (annotations), so other readers show them
-- too. A list buffer per PDF shows them to edit; :w saves it into the file.
local lists = {} -- list buffer: { pdf = its PDF's buffer, file, shown = by id }

-- color(): the colour new comments get, as "#rrggbb".
local function color()
  local c = M.config.color
  return M.config.colors[c] or c
end

-- new_comment(st, page, content): apply's add for a comment on page, in the
-- colour chosen: on the text selected on it, else at the spot clicked on it,
-- else the top left of what the window shows of it, else of the page.
local function new_comment(st, page, content)
  local s, p = st.select, st.point
  local at
  if s and s.page == page then
    at = { x = s.a.x, y = s.a.y, select = { a = s.a, b = s.b } }
  elseif p and p.page == page then
    at = { x = p.x, y = p.y }
  elseif page == st.page then
    at = { x = st.x + 10, y = st.y + 10 }
  else
    at = { x = 20, y = 20 }
  end
  return vim.tbl_extend('force', at, { ['do'] = 'add', page = page, content = content, color = color() })
end

-- forget(buf): let go of the spot and text marked in buf's PDF.
local function forget(buf)
  local st = vim.b[buf].pdf
  if st and (st.point or st.select) then
    local drawn = st.select
    st.point, st.select, st.selected = nil, nil, nil
    vim.b[buf].pdf = st
    if drawn then
      M.redraw()
    end
  end
end

-- fill(lbuf, comments): show comments in the list buffer lbuf.
local function fill(lbuf, comments)
  local l = lists[lbuf]
  local top = function(c) return math.min(c.rect[2], c.rect[4]) end
  table.sort(comments, function(a, b)
    if a.page ~= b.page then
      return a.page < b.page
    end
    return top(a) < top(b)
  end)
  local lines = {
    '" ' .. vim.fn.fnamemodify(l.file, ':t') .. ': change, delete or add lines, then :w saves them in it',
    '" a new one: p<page> text, or just text for the page shown; indent to go on',
  }
  l.shown = {}
  for _, c in ipairs(comments) do
    l.shown[c.id] = c
    local t = text(c.content)
    lines[#lines + 1] = string.format('p%d #%d  %s', c.page + 1, c.id, t[1] or '')
    for i = 2, #t do
      lines[#lines + 1] = '    ' .. t[i]
    end
  end
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
  vim.bo[lbuf].modified = false
end

-- entries(lines): the list's comments, each { page, id, content }; page and
-- id nil when the line does not give them.
local function entries(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if line:match('^"') or vim.trim(line) == '' then
      -- a hint, or room
    elseif line:match('^%s') and #out > 0 then
      table.insert(out[#out].lines, vim.trim(line))
    else
      local page, id, t = line:match('^p(%d+)%s+#(%d+)%s*(.*)$')
      if not page then
        page, t = line:match('^p(%d+)%s+(.*)$')
      end
      out[#out + 1] = { page = page and tonumber(page) - 1, id = tonumber(id), lines = text(t or line) }
    end
  end
  for _, e in ipairs(out) do
    e.content = table.concat(e.lines, '\n')
  end
  return out
end

-- buf_win(buf): a window of this tab showing buf.
local function buf_win(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

-- change(file, changes, lbuf): save changes into file, then show what it has
-- in its lists (lbuf's even when modified: they are its changes) and pages.
local function change(file, changes, lbuf)
  if #changes == 0 then
    if lbuf then
      vim.bo[lbuf].modified = false
    end
    return
  end
  op({ op = 'apply', file = file, changes = changes }, function(r)
    for b, l in pairs(lists) do
      if l.file == file and vim.api.nvim_buf_is_valid(b) and (b == lbuf or not vim.bo[b].modified) then
        fill(b, r.comments)
      end
    end
    M.redraw()
  end)
end

-- save(lbuf): the list's edits into the PDF, against what it showed.
local function save(lbuf)
  local l = lists[lbuf]
  local st = vim.b[l.pdf].pdf or {}
  local changes, seen = {}, {}
  local function add(e)
    local page = e.page or st.page or 0
    changes[#changes + 1] = new_comment(st, page, e.content)
  end
  for _, e in ipairs(entries(vim.api.nvim_buf_get_lines(lbuf, 0, -1, false))) do
    local old = e.id and not seen[e.id] and l.shown[e.id]
    if old then
      seen[e.id] = true
      if e.page ~= old.page then
        -- moved to another page: a new one there
        changes[#changes + 1] = { ['do'] = 'delete', id = e.id }
        add(e)
      elseif e.content ~= table.concat(text(old.content), '\n') then
        changes[#changes + 1] = { ['do'] = 'set', id = e.id, content = e.content }
      end
    elseif e.content ~= '' then
      add(e) -- new, or a line copied
    end
  end
  for id in pairs(l.shown) do
    if not seen[id] then
      changes[#changes + 1] = { ['do'] = 'delete', id = id }
    end
  end
  forget(l.pdf)
  change(l.file, changes, lbuf)
end

-- jump(): show the comment under the cursor, in its PDF's window.
local function jump()
  local l = lists[vim.api.nvim_get_current_buf()]
  local n = vim.fn.line('.')
  while n > 1 and vim.fn.getline(n):match('^%s') do
    n = n - 1
  end
  local e = entries({ vim.fn.getline(n) })[1]
  local win = l and e and e.page and buf_win(l.pdf)
  if not win then
    return
  end
  local c = e.id and l.shown[e.id]
  vim.api.nvim_win_call(win, function()
    update(function(st)
      st.page = e.page
      st.y = c and math.max(0, math.min(c.rect[2], c.rect[4]) - (st.vh or 0) / 4) or 0
    end)
  end)
end

-- comments(): open or close the current PDF's comments list beside it.
function M.comments()
  local buf = vim.api.nvim_get_current_buf()
  local st = vim.b[buf].pdf
  if not st then
    return vim.notify('pdf.nvim: not a PDF', vim.log.levels.ERROR)
  end
  local lbuf
  for b, l in pairs(lists) do
    if l.pdf == buf and vim.api.nvim_buf_is_valid(b) then
      lbuf = b
    end
  end
  local open = lbuf and buf_win(lbuf)
  if open then
    return vim.api.nvim_win_close(open, false)
  end
  if not lbuf then
    lbuf = vim.api.nvim_create_buf(false, false)
    lists[lbuf] = { pdf = buf, file = st.file, shown = {} }
    vim.api.nvim_buf_set_name(lbuf, 'pdf-comments://' .. st.file)
    local bo = vim.bo[lbuf]
    bo.buftype, bo.swapfile, bo.bufhidden, bo.filetype = 'acwrite', false, 'hide', 'pdfcomments'
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = lbuf, callback = function() save(lbuf) end })
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = lbuf, callback = function() lists[lbuf] = nil end })
    for _, key in ipairs(M.config.list_keys.jump) do
      vim.keymap.set('n', key, jump, { buffer = lbuf, desc = 'pdf.nvim: show this comment' })
    end
    op({ op = 'comments', file = st.file }, function(r) fill(lbuf, r.comments) end)
  end
  local win = vim.api.nvim_open_win(lbuf, true, { split = 'left', win = 0, width = M.config.comments_width })
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
end

-- comment(): add a comment on the page shown: on the text selected, at the
-- spot clicked, or at the top left of what shows.
function M.comment()
  local buf = vim.api.nvim_get_current_buf()
  local st = vim.b.pdf
  local on = selected(st) and st.selected
  local prompt = on and string.format('comment on "%s": ', vim.fn.strcharpart(on, 0, 30))
    or string.format('comment on page %d: ', st.page + 1)
  vim.ui.input({ prompt = prompt }, function(t)
    if not t or vim.trim(t) == '' then
      return
    end
    local add = new_comment(st, st.page, t)
    forget(buf)
    change(st.file, { add })
  end)
end

-- at(m, clamp): the point on the current window's page under the mouse m (a
-- getmousepos()), nil off the page unless clamp brings it onto it.
local function at(m, clamp)
  local sh = m and shown[vim.api.nvim_get_current_win()]
  if not sh then
    return
  end
  local b = sh.box
  local c, r = m.screencol - b.col, m.screenrow - b.row
  if clamp then
    c, r = math.max(0, math.min(c, b.w - 1)), math.max(0, math.min(r, b.h - 1))
  elseif c < 0 or r < 0 or c >= b.w or r >= b.h then
    return
  end
  local page, y = page_at(sh, sh.py + (r + 0.5) * sh.rpx)
  return { page = page, x = (sh.px + (c + 0.5) * sh.cpx) / sh.scale, y = y }
end

-- show_comment(c): c's text in the message line, or what a click is for.
local function show_comment(c)
  local msg = c and table.concat(text(c.content), ' / ') or 'spot marked: c comments there, a drag selects text'
  local room = vim.v.echospace - 12
  if vim.fn.strdisplaywidth(msg) > room then
    msg = vim.fn.strcharpart(msg, 0, room - 1) .. '…'
  end
  vim.api.nvim_echo({ { c and 'comment: ' or 'pdf.nvim: ', c and 'Title' or 'None' }, { msg } }, false, {})
end

-- point(m): a click: mark the spot, for the next comment, and where a drag
-- selecting text starts; on a comment's text beside the page, show it.
function M.point(m)
  forget(vim.api.nvim_get_current_buf())
  local p = at(m)
  if not p then
    local sh = shown[m.winid]
    local side = sh and m.screencol < sh.box.col and 'left' or 'right'
    local c = sh and sh.noted and sh.noted[side][m.winrow - 1]
    return c and show_comment(c)
  end
  local st = vim.b.pdf
  st.point = p
  vim.b.pdf = st
  -- on a comment, its text; else what the spot is for
  op({ op = 'at', file = st.file, page = p.page, x = p.x, y = p.y }, function(r)
    show_comment(r.comment)
  end)
end

-- drag(m): select the text from the spot clicked to the mouse.
function M.drag(m)
  local st, p = vim.b.pdf, at(m, true)
  if st.point and p and p.page == st.point.page then
    st.select = { page = p.page, a = st.point, b = p }
    vim.b.pdf = st
    M.redraw()
  end
end

local function scroller(dx, dy, step)
  return function()
    local n = vim.v.count1
    M.scroll(dx * n, dy * n, M.config[step])
  end
end

local actions = {
  next = function() M.go(vim.b.pdf.page + 1 + vim.v.count1) end,
  prev = function() M.go(vim.b.pdf.page + 1 - vim.v.count1) end,
  first = function() M.go(1) end,
  last = function() M.go(vim.b.pdf.count or 1) end,
  down = scroller(0, 1, 'scroll'),
  up = scroller(0, -1, 'scroll'),
  left = scroller(-1, 0, 'scroll'),
  right = scroller(1, 0, 'scroll'),
  wheel_down = scroller(0, 1, 'wheel'),
  wheel_up = scroller(0, -1, 'wheel'),
  wheel_left = scroller(-1, 0, 'wheel'),
  wheel_right = scroller(1, 0, 'wheel'),
  zoom_in = function() M.zoom(M.config.zoom ^ vim.v.count1) end,
  zoom_out = function() M.zoom(M.config.zoom ^ -vim.v.count1) end,
  fit = function() M.zoom() end,
  fit_width = function() M.fit_width() end,
  point = function(m) M.point(m) end,
  drag = function(m) M.drag(m) end,
  release = function() end,
  clear = function() forget(vim.api.nvim_get_current_buf()) end,
  comment = function() M.comment() end,
  comments = function() M.comments() end,
  margin = function() M.margin() end,
}

-- The options a PDF's window has, so all its columns are the page's.
M.pdf_window = {
  number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0',
  colorcolumn = '', cursorline = false, cursorcolumn = false,
}

-- window_options(pdf): give the current window a PDF's options, keeping what
-- it had; or, pdf false, give it back what it had. Window options go with the
-- window, not the buffer, so the next file in it would have them too.
function M.window_options(pdf)
  local saved = vim.w.pdf_saved
  if pdf then
    if not saved then
      saved = {}
      for name in pairs(M.pdf_window) do
        saved[name] = vim.wo[name]
      end
      vim.w.pdf_saved = saved
    end
    for name, value in pairs(M.pdf_window) do
      vim.wo[0][0][name] = value
    end
  elseif saved then
    for name, value in pairs(saved) do
      vim.wo[0][0][name] = value
    end
    vim.w.pdf_saved = nil
  end
end

-- The actions that act on the window under the mouse, not the current one:
-- their keys are mapped everywhere, and do what they did before elsewhere.
-- pass: over a PDF too the key still does its own (a click goes to the
-- window), and the action after. press: the button goes down, so held ones
-- (a drag, until release) go to that window wherever the mouse is.
M.mouse_actions = {
  wheel_down = {}, wheel_up = {}, wheel_left = {}, wheel_right = {},
  point = { pass = true, press = true },
  drag = { held = true },
  release = { held = true, release = true },
}

local held -- the PDF window the button went down in, until it comes up

local mouse_mapped = false

local function map_mouse()
  if mouse_mapped then
    return
  end
  mouse_mapped = true
  for action in pairs(M.mouse_actions) do
    for _, key in ipairs(M.config.keys[action] or {}) do
      vim.keymap.set({ 'n', 'v', 'i' }, key, function()
        local spec, m = M.mouse_actions[action], vim.fn.getmousepos()
        local win = m.winid
        if spec.held then
          win = held
          held = not spec.release and held or nil
          if not win then
            return key
          end
        elseif win == 0 or not vim.b[vim.api.nvim_win_get_buf(win)].pdf then
          return key
        elseif spec.press then
          held = win
        end
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function() actions[action](m) end)
          end
        end)
        return spec.pass and key or ''
      end, { expr = true, replace_keycodes = true, desc = 'pdf.nvim: ' .. action .. ' under the mouse' })
    end
  end
end

-- open(buf): what replaces reading a .pdf into buf.
function M.open(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  vim.b[buf].pdf = { file = file, page = 0, zoom = M.config.view, x = 0, y = 0 }
  local bo = vim.bo[buf]
  bo.buftype, bo.swapfile, bo.bufhidden = 'nofile', false, 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ '' }, vim.o.lines))
  bo.modifiable, bo.modified, bo.filetype = false, false, 'pdf'
  for action, keys in pairs(M.config.keys) do
    if not M.mouse_actions[action] then
      for _, key in ipairs(keys) do
        vim.keymap.set('n', key, actions[action], { buffer = buf, nowait = true })
      end
    end
  end
  map_mouse()
  -- the window's columns all for the page
  vim.api.nvim_create_autocmd('BufWinEnter', { buffer = buf, callback = function() M.window_options(true) end })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'FocusGained', 'CmdlineLeave' }, {
    buffer = buf,
    callback = function() M.redraw(true) end,
  })
  M.window_options(true)
  M.redraw(true)
end

-- position(across, down): where pages sit, as config.position takes it; down
-- nil keeps it, and neither shows where they sit now.
function M.position(across, down)
  local function valid(p, names)
    local n = tonumber(p)
    return (n and n >= 0 and n <= 1) or vim.tbl_contains(names, p)
  end
  if not across then
    local p = M.config.position
    return vim.notify(string.format('pdf.nvim: pages sit %s, %s (:help :PdfPosition)', p[1], p[2]))
  end
  if not valid(across, { 'left', 'center', 'right' }) or (down and not valid(down, { 'top', 'center', 'bottom' })) then
    return vim.notify('pdf.nvim: :PdfPosition {left|center|right|0-1} [{top|center|bottom|0-1}]'
      .. ' (:help :PdfPosition)', vim.log.levels.ERROR)
  end
  remember('position', { across, down or M.config.position[2] })
  M.redraw(true)
end

-- set_color(c): the colour new comments get, as config.color takes it; nil
-- shows it.
function M.set_color(c)
  if not c then
    return vim.notify(string.format('pdf.nvim: new comments are %s (:help :PdfColor)', M.config.color))
  end
  if not M.config.colors[c] and not c:match('^#%x%x%x%x%x%x$') then
    return vim.notify('pdf.nvim: :PdfColor {' .. table.concat(vim.tbl_keys(M.config.colors), '|')
      .. '|#rrggbb} (:help :PdfColor)', vim.log.levels.ERROR)
  end
  remember('color', c)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  apply_saved()
end

apply_saved()

return M
