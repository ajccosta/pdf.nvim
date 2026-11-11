-- A click and a drag on the page.
local comments = require('pdf.comments')
local renderer = require('pdf.renderer')
local util = require('pdf.util')
local view = require('pdf.view')
local P = {}

local op, text, shown, page_at = renderer.op, util.text, view.shown, view.page_at
local edit, forget = comments.edit, comments.forget

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
  local msg = c and table.concat(text(c.content), ' / ') or 'c comments here, a drag or v selects text'
  local room = vim.v.echospace - 30
  if vim.fn.strdisplaywidth(msg) > room then
    msg = vim.fn.strcharpart(msg, 0, room - 1) .. '…'
  end
  vim.api.nvim_echo({ { c and 'comment (c or a double click edits, x deletes): ' or 'pdf.nvim: ', c and 'Title' or 'None' }, { msg } },
    false, {})
end

-- point(m): a click: the cursor goes there, where a drag selecting text
-- starts; on a comment, or its text beside the page, show it.
function P.point(m)
  local buf = vim.api.nvim_get_current_buf()
  forget(buf)
  local p = at(m)
  local st = vim.b.pdf
  if not p then
    local sh = shown[m.winid]
    local side = sh and m.screencol < sh.box.col and 'left' or 'right'
    local c = sh and sh.noted and sh.noted[side][m.winrow - 1]
    if c then
      st.note = { id = c.id, content = c.content, page = c.page }
      vim.b.pdf = st
      edit(buf, st.note)
    end
    return
  end
  st.cursor, st.want = p, nil
  vim.b.pdf = st
  view.redraw()
  op({ op = 'at', file = st.file, page = p.page, x = p.x, y = p.y }, function(r)
    -- a note's icon is for its text; a highlight's text, to select too
    if r.comment and r.comment.type == 'Text' then
      return edit(buf, r.comment)
    end
    show_comment(r.comment)
  end)
end

-- drag(m): select the text from the spot clicked to the mouse.
function P.drag(m)
  local st, p = vim.b.pdf, at(m, true)
  local from = st.visual or st.cursor
  if from and p and p.page == from.page then
    st.visual, st.cursor = st.visual or { page = from.page, x = from.x, y = from.y }, p
    vim.b.pdf = st
    view.redraw()
  end
end

return P
