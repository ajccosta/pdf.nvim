-- pdf.nvim: `nvim file.pdf` shows its pages, drawn in the window with iTerm2's
-- inline image protocol. PyMuPDF renders each page to a PNG.
local M = {}

M.config = {
  python = 'python3', -- one with PyMuPDF (`pip install pymupdf`)
  cell = { 9, 18 }, -- cell size in pixels, when the terminal does not say
  scale = 2, -- render this many times the screen size (retina)
  view = 'width', -- a PDF opens fitting its width; 1 fits the whole page
  scroll = 0.2, -- a scroll moves this much of the window
  zoom = 1.25, -- a zoom in or out multiplies by this
  keys = {
    next = { 'n', '<Space>', '<PageDown>' },
    prev = { 'p', '<BS>', '<PageUp>' },
    first = { 'gg', '<Home>' },
    last = { 'G', '<End>' },
    down = { 'j', '<Down>', '<ScrollWheelDown>' },
    up = { 'k', '<Up>', '<ScrollWheelUp>' },
    left = { 'h', '<Left>', '<ScrollWheelLeft>' },
    right = { 'l', '<Right>', '<ScrollWheelRight>' },
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

-- render(st, w, h, out): what a w x h pixel window shows of st's page, as a PNG
-- at out. Keeps st's offsets on the page and notes how far they go.
local function render(st, w, h, out)
  local r = vim.system({ M.config.python, root .. '/python/render.py',
    st.file, st.page, w, h, st.zoom, st.x, st.y, out }):wait()
  if r.code ~= 0 then
    error('pdf.nvim: ' .. vim.trim(r.stderr), 0)
  end
  local v = vim.tbl_map(tonumber, vim.split(vim.trim(r.stdout), ' '))
  st.count, st.x, st.y, st.mx, st.my = v[1], v[4], v[5], v[6], v[7]
  st.vw, st.vh, st.pw, st.ph, st.zoom = v[8], v[9], v[10], v[11], v[12]
  return v[2], v[3]
end

-- frame(win): the image of win's page and the cells it goes in, or nil.
local function frame(win)
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
  local s = M.config.scale
  vim.fn.mkdir(cache, 'p')
  local png = string.format('%s/%d-%d.png', cache, vim.fn.getpid(), win)
  local ok, pw, ph = pcall(render, st, math.floor(cols * cw * s), math.floor(rows * ch * s), png)
  if not ok then
    vim.notify(pw, vim.log.levels.ERROR)
    return
  end
  vim.b[buf].pdf = st
  local w = math.min(cols, math.ceil(pw / s / cw))
  local h = math.min(rows, math.ceil(ph / s / ch))
  return png, {
    row = info.winrow + math.floor((rows - h) / 2),
    col = info.wincol + info.textoff + math.floor((cols - w) / 2),
    w = w,
    h = h,
  }
end

local function send(png, box)
  local f = assert(io.open(png, 'rb'))
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

-- redraw(clear): draw every window's page. The screen is cleared first (nvim
-- redrawn, which wipes images) when clear is set or an image's cells change;
-- otherwise the new image covers the old one, without a flicker.
function M.redraw(clear)
  vim.schedule(function()
    local frames = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local png, box = frame(win)
      if png then
        clear = clear or not vim.deep_equal(vim.w[win].pdf_box, box)
        vim.w[win].pdf_box = box
        table.insert(frames, { png, box })
      end
    end
    if vim.b.pdf then
      status(vim.b.pdf)
    end
    local function draw()
      for _, f in ipairs(frames) do
        send(f[1], f[2])
      end
    end
    if clear then
      vim.cmd('mode')
      vim.schedule(draw)
    else
      draw()
    end
  end)
end

-- update(f): change the current buffer's state with f, then draw it.
local function update(f)
  local st = vim.b.pdf
  f(st)
  st.page = math.max(0, math.min(st.page, (st.count or 1) - 1))
  vim.b.pdf = st
  M.redraw()
end

-- go(n): show page n (1-based) of the current buffer, from its top.
function M.go(n)
  update(function(st)
    st.page, st.y = n - 1, 0
  end)
end

-- scroll(dx, dy): move by dx, dy scroll steps; past the bottom or top of the
-- page, on to the next or previous one.
function M.scroll(dx, dy)
  update(function(st)
    local step = M.config.scroll
    st.x = st.x + dx * step * (st.vw or 0)
    if dy > 0 and st.y >= (st.my or 0) and st.page + 1 < (st.count or 1) then
      st.page, st.y = st.page + 1, 0
    elseif dy < 0 and st.y <= 0 and st.page > 0 then
      st.page, st.y = st.page - 1, math.huge
    else
      st.y = st.y + dy * step * (st.vh or 0)
    end
  end)
end

-- zoom(by): zoom by a factor, keeping the middle of the window where it is;
-- by nil fits the whole page.
function M.zoom(by)
  update(function(st)
    local z = by and math.max(1, st.zoom * by) or 1
    local r = st.zoom / z
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

local actions = {
  next = function() M.go(vim.b.pdf.page + 1 + vim.v.count1) end,
  prev = function() M.go(vim.b.pdf.page + 1 - vim.v.count1) end,
  first = function() M.go(1) end,
  last = function() M.go(vim.b.pdf.count or 1) end,
  down = function() M.scroll(0, vim.v.count1) end,
  up = function() M.scroll(0, -vim.v.count1) end,
  left = function() M.scroll(-vim.v.count1, 0) end,
  right = function() M.scroll(vim.v.count1, 0) end,
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
