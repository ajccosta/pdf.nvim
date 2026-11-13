-- pdf.nvim: `nvim file.pdf` shows its pages, drawn in the window as images, in
-- the terminal's image protocol (renderer.lua). PyMuPDF renders each page to a
-- PNG, in a process kept running (python/render.py).
local config = require('pdf.config')
local state = require('pdf.state')
local view = require('pdf.view')
local window = require('pdf.window')
require('pdf.paste')

-- what each part offers, as require('pdf') has it
local M = { config = config }
local public = {
  util = { 'positions' },
  state = { 'remembered', 'kept', 'keep_view' },
  window = { 'pdf_window', 'window_options', 'hide_cursor' },
  notes = { 'unnote' },
  view = { 'redraw', 'go', 'scroll', 'zoom', 'fit_width', 'margin' },
  comments = { 'comments', 'export', 'edit_click', 'delete' },
  cursor = { 'motions', 'jumps', 'comment', 'move', 'jump', 'find', 'find_again', 'visual', 'yank' },
  mouse = { 'point', 'drag' },
  keys = { 'mouse_actions' },
  renderer = { 'clear' },
}
for part, names in pairs(public) do
  for _, k in ipairs(names) do
    M[k] = require('pdf.' .. part)[k]
  end
end
local keys = require('pdf.keys')

-- open(buf): what replaces reading a .pdf into buf.
function M.open(buf)
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':p')
  local st = { file = file, page = 0, zoom = config.view, x = 0, y = 0 }
  local v = state.kept_view(file)
  for _, k in ipairs(state.kept) do
    if v[k] ~= nil then
      st[k] = v[k]
    end
  end
  vim.b[buf].pdf = st
  local bo = vim.bo[buf]
  bo.buftype, bo.swapfile, bo.bufhidden, bo.modifiable = 'nofile', false, 'hide', true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn['repeat']({ '' }, vim.o.lines))
  bo.modifiable, bo.modified, bo.filetype = false, false, 'pdf'
  keys.map(buf)
  -- its autocmds once, opened again (:e) or not
  local group = vim.api.nvim_create_augroup('pdf.buf' .. buf, {})
  -- the window's columns all for the page
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function() window.window_options(true) end,
  })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'CmdlineLeave' }, {
    group = group,
    buffer = buf,
    callback = function() view.redraw(true) end,
  })
  -- back from another app: the page drawn again, in place, not the screen
  -- cleared first
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    buffer = buf,
    callback = function() view.redraw() end,
  })
  vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufUnload' }, {
    group = group,
    buffer = buf,
    callback = function() state.keep_view(buf) end,
  })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, buffer = buf, callback = function() window.hide_cursor(true) end })
  vim.api.nvim_create_autocmd('BufLeave', { group = group, buffer = buf, callback = function() window.hide_cursor(false) end })
  window.hide_cursor(true)
  window.window_options(true)
  view.redraw(true)
  -- a terminal just opened may settle on its cell size only after it shows
  -- the window (WezTerm), its columns and lines the same: drawn again then
  local renderer = require('pdf.renderer')
  local cw, ch = renderer.cell_size()
  vim.defer_fn(function()
    local w, h = renderer.cell_size()
    if w ~= cw or h ~= ch then
      view.redraw(true)
    end
  end, 1000)
end

-- position(across, down): where pages sit, as config.position takes it; down
-- nil keeps it, and neither shows where they sit now.
function M.position(across, down)
  local function valid(p, names)
    local n = tonumber(p)
    return (n and n >= 0 and n <= 1) or vim.tbl_contains(names, p)
  end
  if not across then
    local p = config.position
    return vim.notify(string.format('pdf.nvim: pages sit %s, %s (:help :PdfPosition)', p[1], p[2]))
  end
  if not valid(across, { 'left', 'center', 'right' }) or (down and not valid(down, { 'top', 'center', 'bottom' })) then
    return vim.notify('pdf.nvim: :PdfPosition {left|center|right|0-1} [{top|center|bottom|0-1}]'
      .. ' (:help :PdfPosition)', vim.log.levels.ERROR)
  end
  state.remember('position', { across, down or config.position[2] })
  view.redraw(true)
end

-- set_color(c): the colour new comments get, as config.color takes it; nil
-- shows it.
function M.set_color(c)
  if not c then
    return vim.notify(string.format('pdf.nvim: new comments are %s (:help :PdfColor)', config.color))
  end
  if not config.colors[c] and not c:match('^#%x%x%x%x%x%x$') then
    return vim.notify('pdf.nvim: :PdfColor {' .. table.concat(vim.tbl_keys(config.colors), '|')
      .. '|#rrggbb} (:help :PdfColor)', vim.log.levels.ERROR)
  end
  state.remember('color', c)
end

function M.setup(opts)
  -- in place: each part has this table
  for k, v in pairs(vim.tbl_deep_extend('force', config, opts or {})) do
    config[k] = v
  end
  state.apply_saved()
end

state.apply_saved()

return M
