-- The page's text cursor: Vim's motions over its text, the jump list, f F t
-- T, v V and y, and c on it.
local comments = require('pdf.comments')
local renderer = require('pdf.renderer')
local util = require('pdf.util')
local view = require('pdf.view')
local K = {}

local op, shown, selected, in_view, screen_row = renderer.op, view.shown, view.selected, view.in_view, view.screen_row
local edit, under, new_comment, forget = comments.edit, comments.under, comments.new_comment, comments.forget

-- The text cursor's motions, by their keys' action: Vim's, which the
-- renderer's move makes over the page's text.
K.motions = {
  left = 'h', right = 'l', down = 'j', up = 'k', word = 'w', word_end = 'e', word_back = 'b',
  line_start = '0', line_text = '^', line_end = '$', paragraph_next = '}', paragraph_prev = '{',
  first = 'gg', last = 'G', screen_top = 'H', screen_middle = 'M', screen_bottom = 'L',
}

-- The motions that are jumps: where the cursor was goes in the jump list
-- (CTRL-O, CTRL-I), as in Vim.
K.jumps = { gg = true, G = true, ['{'] = true, ['}'] = true, H = true, M = true, L = true, ['/'] = true, ['?'] = true }

-- follow(win, st, r): scroll st so the window shows r, the cursor's box (as
-- move replies), a tenth of the window in from its edge when it moves.
local function follow(win, st, r)
  local sh = shown[win]
  if not sh then
    return
  end
  local s = sh.scale
  local vh, vw = sh.rows * sh.rpx / s, sh.iw / s
  local top = (sh.target or sh.py) / s
  local off = sh.tops and (sh.tops[r.page + 1] or 0) / s or 0
  local away = (not sh.tops and r.page ~= sh.page) and (r.page < sh.page and -1 or 1)
    or (off + r.y0 < top and -1) or (off + r.y1 > top + vh and 1)
  if away then
    st.page, st.y = r.page, away < 0 and r.y0 - vh / 10 or r.y1 - vh * 9 / 10
  end
  local left = sh.px / s
  if r.x0 < left or r.x1 > left + vw then
    st.x = math.max(0, r.x0 < left and r.x0 - vw / 10 or r.x1 - vw * 9 / 10)
  end
end

local moving = {} -- buffer: the motions waiting for the one out

-- jumped(st): put st's cursor in its jump list, after where CTRL-O has gone
-- back to (what was on from there goes, as with jumpoptions=stack).
local function jumped(st)
  local c = st.cursor
  if not c then
    return
  end
  local list = st.jumps or {}
  list = vim.list_slice(list, 1, (st.jump or #list + 1) - 1)
  local last = list[#list]
  if not (last and last.page == c.page and last.x == c.x and last.y == c.y) then
    list[#list + 1] = { page = c.page, x = c.x, y = c.y }
  end
  st.jumps, st.jump = vim.list_slice(list, math.max(1, #list - 99)), nil
end

-- comment(moved): on the text selected, a new comment; else edit the
-- comment under the cursor, or a new one at the cursor, on the cursor's page.
-- A cursor scrolled away goes to the top of what shows first, as motions take
-- it (moved: it has).
function K.comment(moved)
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local st = vim.b.pdf
  local s = selected(st)
  if s and st.selected then
    return edit(buf, nil, new_comment(st, s.page, ''))
  end
  local from = not moved and not in_view(win, st.cursor) and screen_row(win, 'H')
  if from then
    return K.move('here', 1, { from = from, done = function() K.comment(true) end })
  end
  local page = st.cursor and st.cursor.page or st.page
  under(st, function(c)
    edit(buf, c, not c and new_comment(st, page, '') or nil)
  end)
end

-- move(motion, count, o): move the current PDF's cursor as Vim's motion
-- (motions) moves it; from the top left of what shows when the cursor is
-- not on it. In v, on the page it started on. o: { char } for f F t T, with
-- again for ; and ,; { from } a spot to go to (here) instead; { done } to
-- call once it has moved; { search } for / and ?, as view.search has it.
function K.move(motion, count, o)
  o = o or {}
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local q = moving[buf]
  if q then
    return table.insert(q, { motion, count, o })
  end
  local st = vim.b.pdf
  if K.jumps[motion] then
    jumped(st)
    vim.b.pdf = st
  end
  local from = o.from or st.cursor
  if motion:match('^[HML]$') then
    from, motion = screen_row(win, motion), 'here'
  elseif not o.from and not in_view(win, from) then
    from = { page = st.page, x = st.x, y = st.y }
    motion = motion:match('^[hljkwbe0^$]$') and 'here' or motion
  end
  if not from then
    return
  end
  moving[buf] = {}
  op({
    op = 'move', file = st.file, page = from.page, x = from.x, y = from.y, motion = motion, count = count,
    want = st.cursor == from and st.want or nil, stay = st.visual and true or nil,
    char = o.char, again = o.again,
    search = o.search, wrap = o.search and vim.o.wrapscan or nil,
  }, function(r)
    local queued = moving[buf] or {}
    moving[buf] = nil
    if r.missing then
      -- no matches to show: the last ones gone
      view.search_on = false
      view.notice({ { 'E486: Pattern not found: ' .. o.search.pattern, 'ErrorMsg' } })
      return vim.api.nvim_win_is_valid(win) and view.mark(win)
    end
    if r.error or not vim.api.nvim_buf_is_valid(buf) or r.page == nil then
      return
    end
    local now = vim.b[buf].pdf
    now.cursor, now.want, now.note = { page = r.page, x = r.x, y = r.y }, r.want, nil
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      follow(win, now, r)
    end
    vim.b[buf].pdf = now
    if o.done and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, o.done)
    end
    if #queued > 0 then
      vim.api.nvim_buf_call(buf, function()
        K.move(unpack(queued[1]))
        for i = 2, #queued do
          table.insert(moving[buf], queued[i])
        end
      end)
    elseif vim.api.nvim_win_is_valid(win) then
      view.mark(win)
    end
  end, true)
end

-- jump(n): back n places in the jump list (forward with n < 0), as CTRL-O
-- and CTRL-I.
function K.jump(n)
  local st = vim.b.pdf
  if not st.jump then
    -- from the end: here too, for CTRL-I to come back to
    jumped(st)
    st.jump = #(st.jumps or {})
  end
  local to = st.jump - n
  local spot = st.jumps[to]
  if not spot then
    vim.b.pdf = st
    return
  end
  st.jump = to
  vim.b.pdf = st
  K.move('here', 0, { from = spot })
end

local last_find -- { motion, char }: the last f, F, t or T, for ; and ,
local reverse = { f = 'F', F = 'f', t = 'T', T = 't' }

-- find(motion): f, F, t or T: to the character typed next on the line.
function K.find(motion)
  local count = vim.v.count
  local ok, ch = pcall(vim.fn.getcharstr)
  if not ok or ch == '\27' then
    return
  end
  last_find = { motion, ch }
  K.move(motion, count, { char = ch })
end

-- find_again(back): ; (the last f, F, t or T again) or , (the other way).
function K.find_again(back)
  if last_find then
    local motion = back and reverse[last_find[1]] or last_find[1]
    K.move(motion, vim.v.count, { char = last_find[2], again = true })
  end
end

-- search(back): / (? with back): to the next match of the text typed then
-- (the last search's when none), its matches shown until <Esc>. The text is
-- plain, matched as 'ignorecase' and 'smartcase' say, or \c and \C in it.
function K.search(back)
  local count = vim.v.count1
  local ok, typed = pcall(vim.fn.input, { prompt = back and '?' or '/', cancelreturn = false })
  if not ok or typed == false then
    return
  end
  local last = view.search
  if typed == '' then
    if not last then
      return util.say({ { 'E35: No previous regular expression', 'ErrorMsg' } })
    end
    typed = last.pattern
  end
  local ignore = vim.o.ignorecase and not (vim.o.smartcase and typed:match('%u'))
  if typed:match('\\c') then
    ignore = true
  elseif typed:match('\\C') then
    ignore = false
  end
  local pattern = typed:gsub('\\[cC]', '')
  view.search = { pattern = pattern, ignore = ignore, back = back }
  K.search_again(false, count)
end

-- search_again(reverse, count): n (N with reverse): the last search again,
-- the same way (the other), its matches shown again.
function K.search_again(reverse, count)
  local s = view.search
  if not s then
    return util.say({ { 'E35: No previous regular expression', 'ErrorMsg' } })
  end
  view.search_on = true
  K.move((s.back ~= reverse) and '?' or '/', count or vim.v.count1, { search = { pattern = s.pattern, ignore = s.ignore } })
end

-- unsearch(): the search's matches hidden, as :nohlsearch.
function K.unsearch()
  if view.search_on then
    view.search_on = false
    view.mark()
  end
end

-- visual(lines): start selecting text from the cursor (whole lines with
-- lines), as v and V; again, stop.
function K.visual(lines)
  local buf = vim.api.nvim_get_current_buf()
  local st = vim.b.pdf
  if st.visual and (st.visual.lines or false) == lines then
    return forget(buf)
  end
  if not st.cursor then
    return K.move('here')
  end
  -- v in V, or V in v: the other way, from where it started
  local from = st.visual or st.cursor
  st.visual = { page = from.page, x = from.x, y = from.y, lines = lines or nil }
  vim.b.pdf = st
  view.mark()
end

-- yank(): copy the text selected into the register (as y: "+y the clipboard,
-- and with 'clipboard' unnamed or unnamedplus, y too).
function K.yank()
  local st = vim.b.pdf
  if not (selected(st) and st.selected) then
    return vim.notify('pdf.nvim: no text selected (v selects)')
  end
  -- v:register in a mapping is " whatever 'clipboard' says
  local reg = vim.v.register
  if reg == '"' then
    local cb = vim.opt.clipboard:get()
    reg = vim.list_contains(cb, 'unnamedplus') and '+' or vim.list_contains(cb, 'unnamed') and '*' or reg
  end
  vim.fn.setreg(reg, st.selected)
  util.say({ { string.format('copied "%s"', vim.fn.strcharpart(st.selected, 0, 50)) } })
  forget(vim.api.nvim_get_current_buf())
end

return K
