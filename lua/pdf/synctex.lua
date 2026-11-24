-- SyncTeX, as Overleaf has it: a double click on the page opens the source
-- it came from, and one on a .tex file's text shows where it is on the page.
-- TeX writes the links with -synctex=1 (latexmk -synctex=1); the synctex
-- command reads them.
local config = require('pdf.config')
local cursor = require('pdf.cursor')
local view = require('pdf.view')
local S = {}

-- data(pdf): the directory with pdf's .synctex(.gz), next to it or in one of
-- config.synctex.dirs (a build directory).
local function data(pdf)
  local dir, stem = vim.fn.fnamemodify(pdf, ':h'), vim.fn.fnamemodify(pdf, ':t:r')
  for _, d in ipairs(config.synctex.dirs) do
    local at = vim.fs.normalize(dir .. '/' .. d)
    for _, ext in ipairs({ '.synctex.gz', '.synctex' }) do
      if vim.uv.fs_stat(at .. '/' .. stem .. ext) then
        return at
      end
    end
  end
end

-- run(args, pdf): what synctex says, as a list of records (key: value), or
-- nil without the PDF's SyncTeX.
local function run(args, pdf)
  local dir = data(pdf)
  if not dir then
    return
  end
  local cmd = vim.list_extend({ config.synctex.cmd }, args)
  vim.list_extend(cmd, { '-d', dir })
  local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait() end)
  if not ok or r.code ~= 0 then
    return {}
  end
  local list, rec = {}, nil
  for line in r.stdout:gmatch('[^\n]+') do
    local k, v = line:match('^(%a+):(.*)$')
    if k == 'Output' then
      rec = {}
      list[#list + 1] = rec
    end
    if k and rec then
      rec[k] = v
    end
  end
  return list
end

-- flash(buf, line): light up line a moment, to find it. buf a number, not 0:
-- the current buffer then may be another by the time it goes out (a click
-- more, back on the PDF).
local function flash(buf, line)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local ns = vim.api.nvim_create_namespace('pdf.synctex')
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { line_hl_group = config.synctex.flash, priority = 200 })
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end, config.synctex.flash_ms)
end

-- source(p): open the source of p, a spot on the current PDF's pages, at its
-- line: in the window showing that file, else the last one that showed
-- another file, else a split beside the PDF. False without SyncTeX there.
function S.source(p)
  local st = vim.b.pdf
  local list = p and run({ 'edit', '-o', string.format('%d:%f:%f:%s', p.page + 1, p.x, p.y, st.file) }, st.file)
  if not list then
    return false
  end
  local r = list[1]
  local file, line = r and r.Input and vim.fs.normalize(r.Input), r and tonumber(r.Line)
  if not (file and line) then
    vim.notify('pdf.nvim: SyncTeX knows no source there')
    return true
  end
  file = vim.uv.fs_realpath(file) or file
  -- the window showing it, else the one before (#), else any with a file
  local prev, mine, other = vim.fn.win_getid(vim.fn.winnr('#')), nil, nil
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative == '' and not vim.b[b].pdf and vim.bo[b].buftype == '' then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= '' and (vim.uv.fs_realpath(name) or name) == file then
        mine = mine or w
      elseif not other or w == prev then
        other = w
      end
    end
  end
  local win = mine or other
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('leftabove vsplit')
  end
  if (vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or '') ~= file then
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  line = math.min(line, vim.api.nvim_buf_line_count(0))
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd('normal! zz^')
  flash(0, line)
end

-- lit(list, page): the boxes of list's records on page (0-based), in points
-- from the page's top left: where the line is there, to flash.
local function lit(list, page)
  local boxes = {}
  for _, r in ipairs(list) do
    local h, v, W, H = tonumber(r.h), tonumber(r.v), tonumber(r.W), tonumber(r.H)
    if tonumber(r.Page) == page + 1 and h and v and W and H then
      boxes[#boxes + 1] = { page = page, x0 = h, y0 = v - H, x1 = h + W, y1 = v }
    end
  end
  return boxes
end

-- show(m): show in a PDF where the current file's text under the mouse m (a
-- getmousepos()) is: the PDF's window in this tab that has it, the cursor
-- put there (CTRL-O there goes back), the line lit up a moment.
function S.show(m)
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' or vim.bo.buftype ~= '' or not config.synctex.sources[vim.bo.filetype] then
    return
  end
  file = vim.uv.fs_realpath(file) or file
  local line, col = m.line > 0 and m.line or vim.fn.line('.'), math.max(m.column, 1)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local st = vim.b[vim.api.nvim_win_get_buf(w)].pdf
    local list = st and run({ 'view', '-i', string.format('%d:%d:%s', line, col, file), '-o', st.file }, st.file)
    local r = list and list[1]
    if r and tonumber(r.Page) then
      local spot = { page = tonumber(r.Page) - 1, x = tonumber(r.x), y = tonumber(r.y) - tonumber(r.H) / 3 }
      return vim.api.nvim_win_call(w, function()
        st = vim.b.pdf
        cursor.jumped(st)
        st.flash = lit(list, spot.page)
        vim.b.pdf = st
        cursor.move('here', 0, { from = spot })
        local buf = vim.api.nvim_get_current_buf()
        vim.defer_fn(function()
          local now = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].pdf
          if now and now.flash then
            now.flash = nil
            vim.b[buf].pdf = now
            if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
              view.mark(w)
            end
          end
        end, config.synctex.flash_ms)
      end)
    end
  end
  vim.notify('pdf.nvim: no PDF in this tab has this line (built with -synctex=1?)')
end

return S
