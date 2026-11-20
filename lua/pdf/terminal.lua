-- The terminal: its cells' shape, and drawing images in them, all at once
-- (frame), in whole (draw), or moving what is drawn up or down (roll).
local config = require('pdf.config')
local T = {}

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

-- cell_size(): the size in pixels to draw a cell at: config.cell's height,
-- the width as the terminal's cells are shaped. Their pixels (a Retina
-- screen's, or not) would only change how sharp pages are, which
-- config.scale says.
function T.cell_size()
  local w, h = terminal_cell()
  if not w then
    return config.cell[1], config.cell[2]
  end
  return config.cell[2] * w / h, config.cell[2]
end

-- One synchronized update: the terminal shows nothing of it until it ends.
local hold, release = '\027[?2026h', '\027[?2026l'
local framed = false

-- frame(f): what f sends and nvim redraws meanwhile, shown all at once when
-- it is done. nvim's own synchronized updates are off meanwhile: each of its
-- flushes would end the frame.
function T.frame(f)
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
-- base64) in box's cells from the cursor, stretched to fill them, forget(id):
-- those that take image id away, for a terminal whose images stay until
-- told}. Either moves images with the rows a scroll region scrolls.
local env = vim.env
T.protocols = {
  -- iTerm2's inline images (iTerm2, WezTerm, Rio, VS Code)
  iterm = {
    detect = function() return vim.list_contains({ 'iTerm.app', 'WezTerm', 'rio', 'vscode' }, env.TERM_PROGRAM) end,
    image = function(data, box)
      return string.format('\027]1337;File=inline=1;width=%d;height=%d;preserveAspectRatio=0;doNotMoveCursor=1:%s\007',
        box.w, box.h, data)
    end,
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
  },
}

-- The order to try them in: TERM first, which each terminal sets; then
-- TERM_PROGRAM, which a terminal started from another's shell may inherit.
T.detect = { 'kitty', 'iterm' }

-- protocol(): the one config.protocol names, or the terminal's.
function T.protocol()
  local p = T.protocols[config.protocol]
  if p then
    return p
  end
  for _, name in ipairs(T.detect) do
    if T.protocols[name].detect() then
      return T.protocols[name]
    end
  end
  return T.protocols.iterm
end

-- Each window's images still drawn, for a protocol that forgets them: {id,
-- row, h}, in screen rows.
local images, next_id = {}, (vim.fn.getpid() % 4000) * 1000000

-- forget(win, keep): take away win's images (all, or those keep says no to).
local function forget(win, keep)
  local p, kept = T.protocol(), {}
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
function T.clear(win)
  if not T.protocol().forget then
    return
  end
  for w in pairs(win and { [win] = true } or images) do
    forget(w)
  end
end

-- draw(win, png, box, whole): draw the file png in box's cells, for window
-- win: all it shows, or a strip of whole, what it shows.
function T.draw(win, png, box, whole)
  local f = io.open(png, 'rb')
  if not f then
    return
  end
  local data = vim.base64.encode(f:read('*a'))
  f:close()
  local p = T.protocol()
  next_id = next_id + 1
  local id = next_id
  T.frame(function()
    vim.api.nvim_ui_send(string.format('\0277\027[%d;%dH%s\0278', box.row, box.col, p.image(data, box, id)))
    if p.forget then
      -- those out of the window now, and those this one covers, gone
      whole = whole or box
      forget(win, function(im)
        return im.row + im.h > whole.row and im.row < whole.row + whole.h
          and not (im.row >= box.row and im.row + im.h <= box.row + box.h)
      end)
      table.insert(images[win], { id = id, row = box.row, h = box.h })
    end
  end)
end

-- repaint(wins): have nvim send all of each window in wins again, as if the
-- terminal had none of it: after a roll moved their rows where nvim does not
-- know. Their status lines and separators too.
local function repaint(wins)
  if #wins == 0 then
    return
  end
  local rdb = vim.o.redrawdebug
  -- (else it sends only what changed, which is nothing)
  vim.o.redrawdebug = 'nodelta'
  for _, w in ipairs(wins) do
    vim.api.nvim__redraw({ win = w, valid = false, statusline = true, winbar = true })
  end
  vim.api.nvim__redraw({ flush = true })
  vim.o.redrawdebug = rdb
end

-- roll(win, box, d, beside): move rows box.row to its last up d (down when
-- d < 0), image and all, in one frame with what moved them. Whole lines:
-- iTerm2 loses the images in cells it moves inside left and right margins;
-- so the windows beside, which move too, are sent again (beside).
function T.roll(win, box, d, beside)
  T.frame(function()
    vim.api.nvim_ui_send(table.concat({
      '\0277',
      string.format('\027[%d;%dr', box.row, box.row + box.h - 1),
      string.format('\027[%d;%dH', box.row, box.col),
      d > 0 and string.format('\027[%dS', d) or string.format('\027[%dT', -d),
      '\027[r\0278',
    }))
    repaint(beside)
    for _, im in ipairs(images[win] or {}) do
      im.row = im.row - d
    end
  end)
end

return T
