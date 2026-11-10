-- pdf.nvim: `nvim file.pdf` shows its pages, drawn in the window with iTerm2's
-- inline image protocol. PyMuPDF renders each page to a PNG.
local M = {}

M.config = {
  python = 'python3', -- one with PyMuPDF (`pip install pymupdf`)
  cell = { 9, 18 }, -- cell size in pixels, when the terminal does not say
  scale = 2, -- render this many times the screen size (retina)
  keys = {
    next = { 'n', 'j', 'l', '<Space>', '<PageDown>', '<Down>', '<ScrollWheelDown>' },
    prev = { 'p', 'k', 'h', '<BS>', '<PageUp>', '<Up>', '<ScrollWheelUp>' },
    first = { 'gg', '<Home>' },
    last = { 'G', '<End>' },
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

-- render(file, page, w, h): the PNG of page (0-based) in at most w x h pixels,
-- with the page count and its size.
local function render(file, page, w, h)
  vim.fn.mkdir(cache, 'p')
  local stat = vim.uv.fs_stat(file)
  local key = vim.fn.sha256(file .. (stat and stat.mtime.sec or 0))
  local out = string.format('%s/%s-%d-%dx%d.png', cache, key:sub(1, 16), page, w, h)
  local r = vim.system({ M.config.python, root .. '/python/render.py', file, page, w, h, out }):wait()
  if r.code ~= 0 then
    error('pdf.nvim: ' .. vim.trim(r.stderr), 0)
  end
  local count, pw, ph = r.stdout:match('(%d+) (%d+) (%d+)')
  return out, tonumber(count), tonumber(pw), tonumber(ph)
end

-- draw(win): the buffer's current page in win, centered.
function M.draw(win)
  win = win or vim.api.nvim_get_current_win()
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
  local ok, png, count, pw, ph = pcall(render, st.file, st.page, math.floor(cols * cw * s), math.floor(rows * ch * s))
  if not ok then
    vim.notify(png, vim.log.levels.ERROR)
    return
  end
  st.count = count
  vim.b[buf].pdf = st
  -- the image's size in cells, and where it goes
  local w = math.min(cols, math.ceil(pw / s / cw))
  local h = math.min(rows, math.ceil(ph / s / ch))
  local row = info.winrow + math.floor((rows - h) / 2)
  local col = info.wincol + info.textoff + math.floor((cols - w) / 2)
  local f = assert(io.open(png, 'rb'))
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  vim.api.nvim_ui_send(string.format(
    '\0277\027[%d;%dH\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1;doNotMoveCursor=1:%s\007\0278',
    row, col, w, h, data))
end

-- Redraw after nvim's own redraw, which wipes the image.
function M.redraw()
  vim.schedule(function()
    vim.cmd('mode')
    vim.schedule(function()
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        M.draw(win)
      end
    end)
  end)
end

-- go(n): show page n (1-based) of the current buffer.
function M.go(n)
  local st = vim.b.pdf
  st.page = math.max(0, math.min(n - 1, (st.count or 1) - 1))
  vim.b.pdf = st
  vim.api.nvim_echo({ { string.format('page %d/%d', st.page + 1, st.count or 0) } }, false, {})
  M.redraw()
end

local function step(d)
  return function()
    M.go(vim.b.pdf.page + 1 + d * vim.v.count1)
  end
end

-- open(buf): what replaces reading a .pdf into buf.
function M.open(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  vim.b[buf].pdf = { file = file, page = 0 }
  local bo = vim.bo[buf]
  bo.buftype, bo.swapfile, bo.bufhidden = 'nofile', false, 'hide'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ '' }, vim.o.lines))
  bo.modifiable, bo.modified, bo.filetype = false, false, 'pdf'
  local actions = {
    next = step(1),
    prev = step(-1),
    first = function() M.go(1) end,
    last = function() M.go(vim.b.pdf.count or 1) end,
  }
  for action, keys in pairs(M.config.keys) do
    for _, key in ipairs(keys) do
      vim.keymap.set('n', key, actions[action], { buffer = buf, nowait = true })
    end
  end
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinScrolled', 'FocusGained', 'CmdlineLeave' }, {
    buffer = buf,
    callback = M.redraw,
  })
  M.redraw()
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
end

return M
