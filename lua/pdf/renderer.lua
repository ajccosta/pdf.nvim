-- The renderer, python/render.py, kept running; and drawing its images.
local config = require('pdf.config')
local R = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
R.cache = vim.fn.stdpath('cache') .. '/pdf.nvim'

-- The terminal's cell shape, from TIOCGWINSZ: on the stdio nvim's server
-- shares with the terminal, else on /dev/tty, which the server, apart from
-- its TUI, may not have.
local function terminal_cell()
  local ok, ffi = pcall(require, 'ffi')
  if ok then
    pcall(ffi.cdef, [[
      struct pdf_winsize { unsigned short row, col, xpixel, ypixel; };
      int open(const char *path, int flags);
      int close(int fd);
      int ioctl(int fd, unsigned long req, ...);
    ]])
    local req = vim.fn.has('mac') == 1 and 0x40087468 or 0x5413
    local ws = ffi.new('struct pdf_winsize')
    local function size(fd)
      if fd >= 0 and ffi.C.ioctl(fd, req, ws) == 0 and ws.xpixel > 0 and ws.col > 0 then
        return ws.xpixel / ws.col, ws.ypixel / ws.row
      end
    end
    for fd = 0, 2 do
      local w, h = size(fd)
      if w then
        return w, h
      end
    end
    local fd = ffi.C.open('/dev/tty', 0)
    local w, h = size(fd)
    if fd >= 0 then
      ffi.C.close(fd)
    end
    if w then
      return w, h
    end
  end
end

-- The size in pixels to draw a cell at: config.cell's height, the width as
-- the terminal's cells are shaped. Their pixels (a Retina screen's, or not)
-- would only change how sharp pages are, which config.scale says.
function R.cell_size()
  local w, h = terminal_cell()
  if not w then
    return config.cell[1], config.cell[2]
  end
  return config.cell[2] * w / h, config.cell[2]
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
      -- each line a reply, found by plain finds: a pattern tries each start
      -- to the line's end, and with its comments' text a reply is long
      local out, from = renderer.out .. data, 1
      local nl = out:find('\n', from, true)
      while nl do
        on_reply(out:sub(from, nl - 1))
        from = nl + 1
        nl = out:find('\n', from, true)
      end
      renderer.out = out:sub(from)
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

-- One synchronized update: the terminal shows nothing of it until it ends.
local hold, release = '\027[?2026h', '\027[?2026l'
local framed = false

-- frame(f): what f sends and nvim redraws meanwhile, shown all at once when
-- it is done. nvim's own synchronized updates are off meanwhile: each of its
-- flushes would end the frame.
function R.frame(f)
  if framed then
    return f()
  end
  local sync = vim.o.termsync
  vim.o.termsync = false
  vim.api.nvim_ui_send(hold)
  framed = true
  local ok, err = pcall(f)
  framed = false
  vim.api.nvim__redraw({ flush = true })
  vim.api.nvim_ui_send(release)
  vim.o.termsync = sync
  if not ok then
    error(err, 0)
  end
end

-- The terminal's image protocols, each {detect(): whether the terminal is one
-- that speaks it, image(data, box, id): the escapes that draw data (a PNG, in
-- base64) in box's cells from the cursor, forget(id): those that take image id
-- away, for a terminal whose images stay until told, rolls: whether images
-- move with the rows a scroll region scrolls}.
local env = vim.env
R.protocols = {
  -- iTerm2's inline images (iTerm2, WezTerm, Rio, VS Code)
  iterm = {
    detect = function() return vim.list_contains({ 'iTerm.app', 'WezTerm', 'rio', 'vscode' }, env.TERM_PROGRAM) end,
    image = function(data, box)
      return string.format('\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=1;doNotMoveCursor=1:%s\007',
        box.w, box.h, data)
    end,
    rolls = true,
  },
  -- Kitty's graphics protocol (Kitty, Ghostty): in chunks, under nvim's text
  kitty = {
    detect = function()
      return env.TERM == 'xterm-kitty' or env.TERM == 'xterm-ghostty' or env.TERM_PROGRAM == 'ghostty'
        or env.KITTY_WINDOW_ID ~= nil
    end,
    image = function(data, box, id)
      local out, size = {}, 4096
      for at = 1, #data, size do
        local more = at + size <= #data and 1 or 0
        out[#out + 1] = at == 1
          and string.format('\027_Ga=T,f=100,t=d,i=%d,c=%d,r=%d,C=1,z=-1,q=2,m=%d;', id, box.w, box.h, more)
          or string.format('\027_Gm=%d;', more)
        out[#out + 1] = data:sub(at, at + size - 1) .. '\027\\'
      end
      return table.concat(out)
    end,
    forget = function(id) return string.format('\027_Ga=d,d=I,i=%d,q=2\027\\', id) end,
    rolls = true,
  },
}

-- The order to try them in: TERM first, which each terminal sets; then
-- TERM_PROGRAM, which a terminal started from another's shell may inherit.
R.detect = { 'kitty', 'iterm' }

-- protocol(): the one config.protocol names, or the terminal's.
function R.protocol()
  local p = R.protocols[config.protocol]
  if p then
    return p
  end
  for _, name in ipairs(R.detect) do
    if R.protocols[name].detect() then
      return R.protocols[name]
    end
  end
  return R.protocols.iterm
end

-- Each window's images still drawn, for a protocol that forgets them: {id,
-- row, h}, in screen rows.
local images, next_id = {}, (vim.fn.getpid() % 4000) * 1000000

-- forget(win, keep): take away win's images (all, or those keep says no to).
local function forget(win, keep)
  local p, kept = R.protocol(), {}
  for _, im in ipairs(images[win] or {}) do
    if keep and keep(im) then
      kept[#kept + 1] = im
    else
      vim.api.nvim_ui_send(p.forget(im.id))
    end
  end
  images[win] = kept
end

-- clear(win): take win's page away, where the terminal keeps it until told
-- (nil: every window's).
function R.clear(win)
  if not R.protocol().forget then
    return
  end
  for w in pairs(win and { [win] = true } or images) do
    forget(w)
  end
end

-- send(png, box, opts): draw png in box's cells, for window opts.win: all of
-- what it shows, or a strip of opts.whole (what it shows), with opts.roll
-- after the escapes opts.before moved its rows opts.roll up (down when < 0).
-- In a frame, so rows before moves show only with png in them.
function R.send(png, box, opts)
  local f = io.open(png, 'rb')
  if not f then
    return
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  local p = R.protocol()
  next_id = next_id + 1
  local id = next_id
  R.frame(function()
    vim.api.nvim_ui_send(string.format('\0277%s\027[%d;%dH%s\0278', opts.before or '', box.row, box.col,
      p.image(data, box, id)))
    if p.forget then
      -- the images moved with the rows (opts.roll), those then out of the
      -- window's (opts.whole) gone, and those this one covers
      local whole = opts.whole or box
      forget(opts.win, function(im)
        im.row = im.row - (opts.roll or 0)
        return im.row + im.h > whole.row and im.row < whole.row + whole.h
          and not (im.row >= box.row and im.row + im.h <= box.row + box.h)
      end)
      table.insert(images[opts.win], { id = id, row = box.row, h = box.h })
    end
  end)
end

return R
