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
  view = 'width', -- a PDF opens fitting its width; 1 fits the whole page
  scroll = 0.2, -- a scroll key moves this much of the window
  wheel = 0.05, -- and a wheel tick this much
  zoom = 1.25, -- a zoom in or out multiplies by this
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
  },
}

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

local function send(png, box)
  local f = io.open(png, 'rb')
  if not f then
    return
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  vim.api.nvim_ui_send(string.format(
    '\0277\027[%d;%dH\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1;doNotMoveCursor=1:%s\007\0278',
    box.row, box.col, box.w, box.h, data))
end

local function status(st)
  local zoom = math.abs(st.zoom - 1) < 0.01 and '' or string.format('  %d%%', st.zoom * 100)
  vim.api.nvim_echo({ { string.format('page %d/%d%s', st.page + 1, st.count or 0, zoom) } }, false, {})
end

-- draw(win, clear, scale): render win's page and draw it. nvim's own redraw
-- (:mode) wipes the old image first when clear is set or the image's cells
-- change; otherwise the new image covers the old one, without a flicker.
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
  vim.fn.mkdir(cache, 'p')
  local png = string.format('%s/%d-%d.png', cache, vim.fn.getpid(), win)
  request({
    id = win, file = st.file, page = st.page, zoom = st.zoom,
    x = st.x, y = st.y, out = png,
    width = math.floor(cols * cw * scale), height = math.floor(rows * ch * scale),
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
    now.count, now.mx, now.my, now.vw, now.vh = r.count, r.mx, r.my, r.vw, r.vh
    vim.b[buf].pdf = now
    local w = math.min(cols, math.ceil(r.iw / scale / cw))
    local h = math.min(rows, math.ceil(r.ih / scale / ch))
    local box = {
      row = info.winrow + math.floor((rows - h) / 2),
      col = info.wincol + info.textoff + math.floor((cols - w) / 2),
      w = w,
      h = h,
    }
    if vim.api.nvim_get_current_buf() == buf then
      status(now)
    end
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

-- scroll(dx, dy, step): move by dx, dy steps of step of the window; past the
-- bottom or top of the page, on to the next or previous one.
function M.scroll(dx, dy, step)
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
  end, true)
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
}

-- open(buf): what replaces reading a .pdf into buf.
function M.open(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  vim.b[buf].pdf = { file = file, page = 0, zoom = M.config.view, x = 0, y = 0 }
  local bo = vim.bo[buf]
  bo.buftype, bo.swapfile, bo.bufhidden = 'nofile', false, 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ '' }, vim.o.lines))
  bo.modifiable, bo.modified, bo.filetype = false, false, 'pdf'
  for action, keys in pairs(M.config.keys) do
    for _, key in ipairs(keys) do
      vim.keymap.set('n', key, actions[action], { buffer = buf, nowait = true })
    end
  end
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinScrolled', 'FocusGained', 'CmdlineLeave' }, {
    buffer = buf,
    callback = function() M.redraw(true) end,
  })
  M.redraw(true)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

return M
