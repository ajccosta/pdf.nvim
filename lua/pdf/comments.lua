-- The PDF's comments: the list of them, and the editor of one.
local config = require('pdf.config')
local notes = require('pdf.notes')
local renderer = require('pdf.renderer')
local util = require('pdf.util')
local view = require('pdf.view')
local C = {}

local op, text, buf_win = renderer.op, util.text, util.buf_win
local selected, update = view.selected, view.update

-- Comments: the PDF's own notes (annotations), so other readers show them
-- too. A list buffer per PDF shows them to edit; :w saves it into the file.
local lists = {} -- list buffer: { pdf = its PDF's buffer, file, shown = by id }

-- color(): the colour new comments get, as "#rrggbb".
local function color()
  local c = config.color
  return config.colors[c] or c
end

-- new_comment(st, page, content): apply's add for a comment on page, in the
-- colour chosen: on the text selected on it, else at the cursor on it,
-- else the top left of what the window shows of it, else of the page.
local function new_comment(st, page, content)
  local s, p = selected(st), st.cursor
  local at
  if s and s.page == page then
    at = { x = s.a.x, y = s.a.y, select = { a = s.a, b = s.b, lines = s.lines } }
  elseif p and p.page == page then
    at = { x = p.x, y = p.y }
  elseif page == st.page then
    at = { x = st.x + 10, y = st.y + 10 }
  else
    at = { x = 20, y = 20 }
  end
  return vim.tbl_extend('force', at, { ['do'] = 'add', page = page, content = content, color = color() })
end

-- forget(buf): let go of the text selected in buf's PDF.
local function forget(buf)
  local st = vim.b[buf].pdf
  if st and (st.visual or st.selected or st.note) then
    local drawn = st.visual
    st.visual, st.selected, st.note = nil, nil, nil
    vim.b[buf].pdf = st
    if drawn then
      view.redraw()
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



-- change(file, changes, lbuf, cb): save changes into file, then show what it
-- has in its lists (lbuf's even when modified: they are its changes) and
-- pages, then cb with apply's reply.
local function change(file, changes, lbuf, cb)
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
    view.redraw()
    if cb then
      cb(r)
    end
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
function C.comments()
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
    for _, key in ipairs(config.list_keys.jump) do
      vim.keymap.set('n', key, jump, { buffer = lbuf, desc = 'pdf.nvim: show this comment' })
    end
    op({ op = 'comments', file = st.file }, function(r) fill(lbuf, r.comments) end)
  end
  local win = vim.api.nvim_open_win(lbuf, true, { split = 'left', win = 0, width = config.comments_width })
  vim.wo[win][0].wrap, vim.wo[win][0].linebreak = true, true
end

-- under(st, cb): cb with the comment under the cursor, or the one clicked
-- beside the page ({ id, content }); nil when none.
local function under(st, cb)
  if st.note then
    return cb(st.note)
  end
  local c = st.cursor
  if not c then
    return cb(nil)
  end
  op({ op = 'at', file = st.file, page = c.page, x = c.x, y = c.y }, function(r) cb(r.comment) end)
end

local editors = {} -- buffer: the comment it edits, { pdf, file, id, add }

local function editor_name(file, id)
  return string.format('pdf-comment://%s#%s', vim.fn.fnamemodify(file, ':t'), id)
end

-- write_comment(ebuf): the editor's text into its comment: a new one (add,
-- apply's add for it) the first time, none when empty.
local function write_comment(ebuf)
  local e = editors[ebuf]
  local t = vim.trim(table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), '\n'))
  local c
  if e.id then
    c = t == '' and { ['do'] = 'delete', id = e.id } or { ['do'] = 'set', id = e.id, content = t }
  elseif t ~= '' then
    c = vim.tbl_extend('force', e.add, { content = t })
  else
    vim.bo[ebuf].modified = false
    return
  end
  if c['do'] == 'add' then
    forget(e.pdf) -- the text it is on, shown selected until now
  end
  -- written: so :x and :wq close it now, not after the PDF is
  vim.bo[ebuf].modified = false
  change(e.file, { c }, nil, function(r)
    if not vim.api.nvim_buf_is_valid(ebuf) then
      return
    end
    if c['do'] == 'delete' then
      -- what is written next is a new one where it was
      e.id = nil
      vim.notify('pdf.nvim: comment deleted')
    elseif c['do'] == 'add' then
      e.id = r.added and r.added[1]
      if e.id then
        vim.api.nvim_buf_set_name(ebuf, editor_name(e.file, e.id))
      end
    end
  end)
end

-- delete_comment(ebuf): delete the comment ebuf edits (a new one is only
-- dropped), and close ebuf.
local function delete_comment(ebuf)
  local e = editors[ebuf]
  local function close()
    if vim.api.nvim_buf_is_valid(ebuf) then
      vim.api.nvim_buf_delete(ebuf, { force = true })
    end
  end
  if not e.id then
    forget(e.pdf)
    return close()
  end
  change(e.file, { { ['do'] = 'delete', id = e.id } }, nil, function()
    vim.notify('pdf.nvim: comment deleted')
    close()
  end)
end

-- The editor's keys that move by the rows it shows, not its real lines.
local rows = { j = 'gj', k = 'gk', ['<Down>'] = 'gj', ['<Up>'] = 'gk' }

-- close_on_leave(win, ebuf): close win, ebuf's window over the page, once
-- another window is the current one (a click on the page, or on another
-- comment): with its text saved, as :x would.
local function close_on_leave(win, ebuf)
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = ebuf,
    once = true,
    callback = function()
      -- after the leaving: no window closes while it happens
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(win) then
          return
        end
        if vim.api.nvim_buf_is_valid(ebuf) and vim.bo[ebuf].modified then
          write_comment(ebuf)
        end
        vim.api.nvim_win_close(win, true)
      end)
    end,
  })
end

-- inplace(pwin, spot, ebuf): a window on ebuf over the box spot (as
-- notes.box gives it) beside the page in pwin, as tall as all of its text
-- and at least the box. Closing it, nvim redraws the screen and with it
-- wipes the page's image: drawn again then.
local function inplace(pwin, spot, ebuf, hl)
  local win = vim.api.nvim_open_win(ebuf, true, {
    relative = 'win', win = pwin, row = spot.row, col = spot.col, width = spot.width, height = 1,
    border = 'single', style = 'minimal', zindex = 40,
    footer = vim.fn.strcharpart(' :w save  :x save+quit  :q quit ', 0, spot.width), footer_pos = 'center',
  })
  local wo = vim.wo[win][0]
  wo.wrap, wo.linebreak, wo.foldcolumn = true, true, '1' -- a column of room left, as in the box
  wo.winhighlight = 'NormalFloat:Normal,FloatBorder:' .. hl .. ',FloatFooter:' .. hl
  -- fit(): as tall as its text, moved up when that would go past the bottom
  local function fit()
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_win_is_valid(pwin) then
      return
    end
    local room = vim.api.nvim_win_get_height(pwin) - 2
    local h = math.max(spot.height, math.min(vim.api.nvim_win_text_height(win, {}).all, room))
    vim.api.nvim_win_set_config(win, {
      relative = 'win', win = pwin, row = math.max(0, math.min(spot.row, room - h)), col = spot.col, height = h,
    })
  end
  fit()
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = ebuf, callback = fit })
  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true, callback = function() view.redraw(true) end,
  })
  return win
end

-- edit(buf, c, add): edit comment c of buf's PDF ({ id, content, page }), or
-- a new one (add: apply's add for it), as text where it shows beside the
-- page (notes.box), else in a buffer below the PDF: :w saves it into the
-- PDF, :x saves and closes, :d (or :w with no text) deletes it.
local function edit(buf, c, add)
  local st = vim.b[buf].pdf
  for b, e in pairs(editors) do
    if e.file == st.file and c and e.id == c.id and vim.api.nvim_buf_is_valid(b) then
      local win = buf_win(b)
      if win then
        return vim.api.nvim_set_current_win(win)
      end
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  local ebuf = vim.api.nvim_create_buf(false, false)
  editors[ebuf] = { pdf = buf, file = st.file, id = c and c.id, add = add }
  local page = (c and c.page or add and add.page or st.page) + 1
  vim.api.nvim_buf_set_name(ebuf, editor_name(st.file, c and c.id or ('new' .. ebuf)))
  local bo = vim.bo[ebuf]
  bo.buftype, bo.swapfile, bo.bufhidden, bo.filetype = 'acwrite', false, 'wipe', 'pdfcomment'
  local lines = c and text(c.content) or {}
  vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, #lines > 0 and lines or { '' })
  bo.modified = false
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = ebuf, callback = function() write_comment(ebuf) end })
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = ebuf, callback = function() editors[ebuf] = nil end })
  vim.api.nvim_buf_create_user_command(ebuf, 'PdfDelete', function() delete_comment(ebuf) end, {})
  -- :d, Vim's delete, as its own whole command line: the comment
  vim.keymap.set('ca', 'd', function()
    return vim.fn.getcmdtype() == ':' and vim.fn.getcmdline() == 'd' and 'PdfDelete' or 'd'
  end, { buffer = ebuf, expr = true })
  -- up and down by the lines it shows, a paragraph wrapping into many; with
  -- a count, by its real lines, as relative numbers count them
  for key, by_row in pairs(rows) do
    vim.keymap.set({ 'n', 'x' }, key, function()
      return vim.v.count == 0 and by_row or key
    end, { buffer = ebuf, expr = true })
  end
  local pwin = buf_win(buf)
  local spot = pwin and notes.box(view.shown[pwin], c and c.id, add)
  local win
  if spot then
    local hl = spot.hl or notes.hl(color())
    win = inplace(pwin, spot, ebuf, hl)
  else
    local height = math.max(3, math.min(config.editor_height, #lines + 1))
    win = vim.api.nvim_open_win(ebuf, true, { split = 'below', win = pwin or 0, height = height })
    local wo = vim.wo[win][0]
    wo.wrap, wo.linebreak = true, true
    wo.winbar = string.format(' %s on page %d: :w saves it in the PDF, :d deletes it, :q closes',
      c and 'comment' or 'new comment', page)
  end
  if c then
    forget(buf)
  end
  -- after the mouse's actions, run in the PDF's window, give it back
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      if spot then
        close_on_leave(win, ebuf)
      end
      if not c then
        vim.cmd.startinsert()
      end
    end
  end)
end

-- edit_click(m): a double click: edit the comment under the mouse.
function C.edit_click()
  local st = vim.b.pdf
  under(st, function(c)
    if c then
      edit(vim.api.nvim_get_current_buf(), c)
    end
  end)
end

-- delete(): delete the comment under the cursor, once confirmed.
function C.delete()
  local buf = vim.api.nvim_get_current_buf()
  local st = vim.b.pdf
  under(st, function(c)
    if not c then
      return vim.notify('pdf.nvim: no comment under the cursor')
    end
    local t = vim.fn.strcharpart(table.concat(text(c.content), ' / '), 0, 40)
    if vim.fn.confirm(string.format('Delete comment "%s"?', t), '&Yes\n&No', 2) == 1 then
      forget(buf)
      change(st.file, { { ['do'] = 'delete', id = c.id } })
    end
  end)
end

C.new_comment, C.forget, C.under, C.edit = new_comment, forget, under, edit

return C
