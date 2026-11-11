-- The renderer, python/render.py, kept running; and drawing its images.
local config = require('pdf.config')
local R = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
R.cache = vim.fn.stdpath('cache') .. '/pdf.nvim'

-- The terminal's cell size in pixels, from TIOCGWINSZ on /dev/tty.
function R.cell_size()
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
  return config.cell[1], config.cell[2]
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
  renderer.proc = vim.system({ config.python, '-u', root .. '/python/render.py' }, {
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

function R.request(req, cb)
  if renderer.busy[req.id] then
    renderer.pending[req.id] = { req, cb }
  else
    send_request(req, cb)
  end
end

-- op(req, cb, always): one of the renderer's other ops (comments, apply);
-- each its own, none dropped for a later one. cb has the reply; on an error,
-- only with always.
local ops = 0
function R.op(req, cb, always)
  ops = ops + 1
  req.id = 'op' .. ops
  send_request(req, function(r)
    if r.error then
      vim.notify('pdf.nvim: ' .. r.error, vim.log.levels.ERROR)
      if not always then
        return
      end
    end
    cb(r)
  end)
end

-- send(png, box, before): draw png in box's cells, after the escapes before;
-- one synchronized update, so rows before moves show only with png in them.
function R.send(png, box, before)
  local f = io.open(png, 'rb')
  if not f then
    return
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  vim.api.nvim_ui_send(string.format(
    '\027[?2026h\0277%s\027[%d;%dH\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1;doNotMoveCursor=1:%s\007\0278\027[?2026l',
    before or '', box.row, box.col, box.w, box.h, data))
end

return R
