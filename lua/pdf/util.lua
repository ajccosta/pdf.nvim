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

-- wrap(lines, width): lines broken at spaces to fit width columns.
function U.wrap(lines, width)
  local out = {}
  for _, l in ipairs(lines) do
    local line = ''
    for word in l:gmatch('%S+') do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= '' then
          out[#out + 1], line = line, ''
        end
        out[#out + 1], word = vim.fn.strcharpart(word, 0, width), vim.fn.strcharpart(word, width)
      end
      if line ~= '' and vim.fn.strdisplaywidth(line .. ' ' .. word) > width then
        out[#out + 1], line = line, word
      else
        line = line == '' and word or line .. ' ' .. word
      end
    end
    out[#out + 1] = line
  end
  return out
end

-- buf_win(buf): a window of this tab showing buf.
function U.buf_win(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

return U
