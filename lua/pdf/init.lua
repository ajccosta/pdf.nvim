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
  view = 'width', -- a PDF opens fitting its width; 1 fits the whole page
  split_empty = true, -- a split of a PDF's window (CTRL-W v) starts empty
  -- where the page sits when it is smaller than the window: across (left,
  -- center, right) and down (top, center, bottom), or a fraction from 0 to 1
  position = { 'right', 'center' },
  scroll = 0.2, -- a scroll key moves this much of the window
  wheel = 0.05, -- and a wheel tick this much
  zoom = 1.25, -- a zoom in or out multiplies by this
  comments_width = 40, -- the comments list's window, in columns
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
M.remembered = { 'position' }
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
  local ok, r = pcall(vim.json.decode, line)
  if not ok then
    return
  end
  local win = r.id
  local cb = renderer.callbacks[win]
  renderer.busy[win], renderer.callbacks[win] = nil, nil
  if cb then
    cb(r)
  end
  local next = renderer.pending[win]
  if next then
    renderer.pending[win] = nil
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

-- selected(st): the text selected on the page shown, as render takes it.
local function selected(st)
  local s = st.select
  return s and s.page == st.page and { a = s.a, b = s.b } or nil
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
  -- the last screen row scrolls the terminal
  rows = math.min(rows, vim.o.lines - 1 - info.winrow)
  if cols < 1 or rows < 1 then
    return
  end
  local cw, ch = cell_size()
  -- a cell's size in pixels, whole so rows stack exactly
  local cpx, rpx = math.floor(cw * scale + 0.5), math.floor(ch * scale + 0.5)
  vim.fn.mkdir(cache, 'p')
  local png = string.format('%s/%d-%d.png', cache, vim.fn.getpid(), win)
  shown[win] = nil
  request({
    id = win, file = st.file, page = st.page, zoom = st.zoom,
    x = st.x, y = st.y, out = png, width = cols * cpx, height = rows * rpx, select = selected(st),
  }, function(r)
    if r.error then
      return vim.notify('pdf.nvim: ' .. r.error, vim.log.levels.ERROR)
    end
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    -- what the renderer kept on the page, unless the state moved on meanwhile
    local now = vim.b[buf].pdf
    if now.page == st.page and now.x == st.x and now.y == st.y and now.zoom == st.zoom then
      now.x, now.y, now.zoom = r.x, r.y, r.zoom
    end
    now.count, now.mx, now.my, now.vw, now.vh, now.notes = r.count, r.mx, r.my, r.vw, r.vh, r.notes
    now.selected = r.selected
    vim.b[buf].pdf = now
    local w = math.min(cols, math.ceil(r.iw / cpx))
    local h = math.min(rows, math.ceil(r.ih / rpx))
    local box = {
      row = info.winrow + math.floor((rows - h) * fraction(M.config.position[2])),
      col = info.wincol + info.textoff + math.floor((cols - w) * fraction(M.config.position[1])),
      w = w,
      h = h,
    }
    if vim.api.nvim_get_current_buf() == buf then
      status(now)
    end
    shown[win] = {
      file = st.file, page = st.page, scale = r.scale, px = r.px, py = r.py, pxh = r.pxh,
      iw = r.iw, rows = rows, cpx = cpx, rpx = rpx, box = box, png = png, select = selected(st),
      -- only a sharp frame filling the window's height scrolls by rows
      rolls = scale == M.config.scale and h == rows and r.ih == rows * rpx,
    }
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

-- roll(sh, d): the escapes that move sh's image d rows up (down when d < 0)
-- inside its cells, leaving the rest of the screen be.
local function roll(sh, d)
  local b = sh.box
  local margins = b.col > 1 or b.col + b.w - 1 < vim.o.columns
  return table.concat({
    margins and '\027[?69h' or '',
    string.format('\027[%d;%dr', b.row, b.row + b.h - 1),
    margins and string.format('\027[%d;%ds', b.col, b.col + b.w - 1) or '',
    string.format('\027[%d;%dH', b.row, b.col),
    d > 0 and string.format('\027[%dS', d) or string.format('\027[%dT', -d),
    margins and '\027[?69l' or '',
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
  request({
    id = win, file = sh.file, page = sh.page, scale = sh.scale,
    px = sh.px, py = py, width = sh.iw, height = h, out = sh.png, select = sh.select,
  }, function(r)
    if shown[win] ~= sh then
      return
    end
    sh.busy = false
    if r.error or r.py ~= py or r.ih ~= h or r.iw ~= sh.iw then
      return draw(win, false, M.config.scale)
    end
    local b = sh.box
    send(sh.png, {
      row = d > 0 and b.row + b.h - d or b.row, col = b.col, w = b.w, h = math.abs(d),
    }, roll(sh, d))
    sh.py = sh.py + d * sh.rpx
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
  st.y = sh.target / sh.scale
  vim.b.pdf = st
  pump(win)
  return true
end

-- scroll(dx, dy, step): move by dx, dy steps of step of the window; past the
-- bottom or top of the page, on to the next or previous one.
function M.scroll(dx, dy, step)
  if dx == 0 and dy ~= 0 and roll_to(dy, step) then
    return
  end
  update(function(st)
    st.x = st.x + dx * step * (st.vw or 0)
    if dy > 0 and st.y >= (st.my or 0) and st.page + 1 < (st.count or 1) then
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

-- Comments: the PDF's own notes (annotations), so other readers show them
-- too. A list buffer per PDF shows them to edit; :w saves it into the file.
local lists = {} -- list buffer: { pdf = its PDF's buffer, file, shown = by id }

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

-- place(st, page): where a new comment on page goes, as apply's add takes it:
-- on the text selected on it, else at the spot clicked on it, else the top
-- left of what the window shows of it, else of the page.
local function place(st, page)
  local s, p = st.select, st.point
  if s and s.page == page then
    return { x = s.a.x, y = s.a.y, select = { a = s.a, b = s.b } }
  elseif p and p.page == page then
    return { x = p.x, y = p.y }
  elseif page == st.page then
    return { x = st.x + 10, y = st.y + 10 }
  end
  return { x = 20, y = 20 }
end

-- forget(buf): let go of the spot and text marked in buf's PDF.
local function forget(buf)
  local st = vim.b[buf].pdf
  if st and (st.point or st.select) then
    st.point, st.select, st.selected = nil, nil, nil
    vim.b[buf].pdf = st
    M.redraw()
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
    changes[#changes + 1] = vim.tbl_extend('force', place(st, page), { ['do'] = 'add', page = page, content = e.content })
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
    local add = vim.tbl_extend('force', place(st, st.page), { ['do'] = 'add', page = st.page, content = t })
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
  return { page = sh.page, x = (sh.px + (c + 0.5) * sh.cpx) / sh.scale, y = (sh.py + (r + 0.5) * sh.rpx) / sh.scale }
end

-- point(m): a click: mark the spot, for the next comment, and where a drag
-- selecting text starts.
function M.point(m)
  forget(vim.api.nvim_get_current_buf())
  local p = at(m)
  if p then
    local st = vim.b.pdf
    st.point = p
    vim.b.pdf = st
    vim.api.nvim_echo({ { 'pdf.nvim: spot marked: c comments there, a drag selects text' } }, false, {})
  end
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
}

-- The options a PDF's window has, so all its columns are the page's.
M.pdf_window = { number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0' }

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

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  apply_saved()
end

apply_saved()

return M
