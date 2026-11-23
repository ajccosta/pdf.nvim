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

-- open(url): a file in a tab of its own (a PDF shows here), the rest by
-- what the system opens it with.
function U.open(url)
  if url:match('^file:') then
    local path = vim.uri_to_fname(url)
    if not vim.uv.fs_stat(path) then
      return vim.notify('pdf.nvim: no file ' .. path, vim.log.levels.WARN)
    end
    return vim.cmd.tabedit(vim.fn.fnameescape(path))
  end
  local _, err = vim.ui.open(url)
  if err then
    vim.notify('pdf.nvim: ' .. err, vim.log.levels.WARN)
  end
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
