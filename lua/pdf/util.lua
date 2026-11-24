-- What several parts use.
local U = {}

-- The positions by name, as fractions of the room left around the page.
U.positions = { left = 0, top = 0, center = 0.5, right = 1, bottom = 1 }

function U.fraction(p)
  return math.max(0, math.min(1, tonumber(p) or U.positions[p] or 0.5))
end

-- text(content): a comment's text as the list has it, its lines trimmed.
function U.text(content)
  local lines = {}
  for _, l in ipairs(vim.split(content or '', '\n')) do
    if vim.trim(l) ~= '' then
      lines[#lines + 1] = vim.trim(l)
    end
  end
  return lines
end

-- wrap(lines, width): lines broken at spaces to fit width columns. Also, for
-- each line it gives, its words: { col: where it starts (from 0), w: its
-- columns, word: the whole word, of which a long one is on several lines }.
function U.wrap(lines, width)
  local out, parts = {}, {}
  for _, l in ipairs(lines) do
    local line, on = '', {}
    local function push()
      out[#out + 1] = line
      parts[#out] = on
      line, on = '', {}
    end
    for word in l:gmatch('%S+') do
      local whole = word
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= '' then
          push()
        end
        line, on = vim.fn.strcharpart(word, 0, width), { { col = 0, w = width, word = whole } }
        push()
        word = vim.fn.strcharpart(word, width)
      end
      if line ~= '' and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
        push()
      end
      on[#on + 1] = { col = line == '' and 0 or vim.fn.strdisplaywidth(line) + 1, w = vim.fn.strdisplaywidth(word), word = whole }
      line = line == '' and word or line .. ' ' .. word
    end
    push()
  end
  return out, parts
end

-- link(word): the link in word (https://..., file:///...), without what a
-- sentence puts around it; nil when it has none.
function U.link(word)
  local url = word and word:match('%a[%w+.-]*://[^%s<>"]+')
  return url and (url:gsub('[.,;:!?)%]}\']+$', ''))
end

-- Where in a file a link's #fragment points, as go() takes it: each form of
-- fragment one entry, the first that reads it wins.
local fragments = {
  -- a text fragment (#:~:text=first%20words, or start,end), as browsers have
  function(f)
    local t = f:match('^:~:text=([^&,]+)')
    return t and { text = vim.uri_decode(t) }
  end,
  -- a search (#search=first%20words&phrase=true), as pdf.js (Firefox) takes it
  function(f)
    local t = f:match('^search=([^&]+)') or f:match('&search=([^&]+)')
    return t and { text = vim.uri_decode(t) }
  end,
  -- a line (#L42), as GitHub's
  function(f)
    local n = f:match('^L(%d+)')
    return n and { line = tonumber(n) }
  end,
  -- a page (#page=3), as PDF viewers take it
  function(f)
    local n = f:match('page=(%d+)')
    return n and { page = tonumber(n) }
  end,
}

-- go(to): the current window to where a fragment points: in a PDF, its
-- page, or the first match of the text (shown as / shows it, n going on);
-- elsewhere, the line, or the text (a whole line of it first, so a heading
-- before a mention), its spaces any run of space or line breaks.
local function go(to)
  if vim.b.pdf then
    if to.page then
      return require('pdf.view').go(to.page)
    end
    local view = require('pdf.view')
    view.search, view.search_on = { pattern = to.text, ignore = false }, true
    return require('pdf.cursor').move('/', 1, { from = { page = 0, x = 0, y = 0 }, search = view.search })
  end
  if to.line then
    vim.api.nvim_win_set_cursor(0, { math.min(to.line, vim.api.nvim_buf_line_count(0)), 0 })
  else
    local words = vim.tbl_map(function(w) return vim.fn.escape(w, '\\') end, vim.split(to.text, '%s+', { trimempty = true }))
    local text = table.concat(words, '\\_s\\+')
    vim.fn.cursor(1, 1)
    if vim.fn.search('\\V\\^\\W\\*' .. text .. '\\W\\*\\$', 'cW') == 0 then
      vim.fn.search('\\V' .. text, 'cW')
    end
  end
  vim.cmd('normal! zt')
end

local function open(url)
  if url:match('^file:') then
    local base, fragment = url:match('^([^#]*)#?(.*)$')
    local path = vim.uri_to_fname(base)
    if not vim.uv.fs_stat(path) then
      return vim.notify('pdf.nvim: no file ' .. path, vim.log.levels.WARN)
    end
    vim.cmd.tabedit(vim.fn.fnameescape(path))
    for _, read in ipairs(fragments) do
      local to = fragment ~= '' and read(fragment)
      if to then
        return go(to)
      end
    end
    return
  end
  local _, err = vim.ui.open(url)
  if err then
    vim.notify('pdf.nvim: ' .. err, vim.log.levels.WARN)
  end
end

-- open(url): a file in a tab of its own (a PDF shows here), at where its
-- #fragment points (fragments), that tab then the current one; the rest by
-- what the system opens it with. Scheduled: called from in nvim_win_call (a
-- click), the tab opened would be left again when that returns.
function U.open(url)
  vim.schedule(function() open(url) end)
end

-- buf_win(buf): a window of this tab showing buf.
function U.buf_win(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

-- say(chunks): nvim_echo's chunks on one line, cut with "…" to fit what the
-- message line has (v:echospace): a longer message, or a line break in it,
-- brings the hit-enter prompt, where nvim stops reporting the mouse.
function U.say(chunks)
  local room, out = vim.v.echospace, {}
  for i, c in ipairs(chunks) do
    local t = c[1]:gsub('%s+', ' ')
    local w = vim.fn.strdisplaywidth(t)
    -- all of room taken before the last chunk leaves none for its "…"
    if w > room or (w == room and i < #chunks) then
      local cut = ''
      for _, ch in ipairs(vim.fn.split(t, [[\zs]])) do
        if vim.fn.strdisplaywidth(cut .. ch) > room - 1 then
          break
        end
        cut = cut .. ch
      end
      out[#out + 1] = { cut .. '…', c[2] }
      break
    end
    room = room - w
    out[#out + 1] = { t, c[2] }
  end
  vim.api.nvim_echo(out, false, {})
end

return U
