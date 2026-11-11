-- What is kept across sessions, in a file in nvim's state directory.
local config = require('pdf.config')
local S = {}

-- The settings a command changes, remembered across sessions: they win over
-- setup's, which are the defaults until one is chosen.
S.remembered = { 'position', 'color' }
local state_file = vim.fn.stdpath('state') .. '/pdf.nvim.json'

local function saved()
  local f = io.open(state_file, 'r')
  if not f then
    return {}
  end
  local ok, t = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(t) == 'table' and t or {}
end

local function write_saved(t)
  vim.fn.mkdir(vim.fn.fnamemodify(state_file, ':h'), 'p')
  local f = io.open(state_file, 'w')
  if f then
    f:write(vim.json.encode(t))
    f:close()
  end
end

-- remember(name, value): set config[name] for this and later sessions.
function S.remember(name, value)
  config[name] = value
  local t = saved()
  t[name] = value
  write_saved(t)
end

-- What of a PDF's view is kept when it is left, to open it there again, for
-- the latest MAX_VIEWS files.
S.kept = { 'page', 'zoom', 'x', 'y' }
local MAX_VIEWS = 200

function S.kept_view(file)
  local views = saved().views
  local v = type(views) == 'table' and views[file]
  return type(v) == 'table' and v or {}
end

-- keep_view(buf): remember where buf's PDF was left.
function S.keep_view(buf)
  local st = vim.api.nvim_buf_is_valid(buf) and vim.b[buf].pdf
  if not st then
    return
  end
  local t = saved()
  local views = type(t.views) == 'table' and t.views or {}
  local v = { at = os.time() }
  for _, k in ipairs(S.kept) do
    v[k] = st[k]
  end
  views[st.file] = v
  local files = vim.tbl_keys(views)
  table.sort(files, function(a, b) return (views[a].at or 0) > (views[b].at or 0) end)
  for i = MAX_VIEWS + 1, #files do
    views[files[i]] = nil
  end
  t.views = views
  write_saved(t)
end

function S.apply_saved()
  local t = saved()
  for _, name in ipairs(S.remembered) do
    if t[name] ~= nil then
      config[name] = t[name]
    end
  end
end

return S
