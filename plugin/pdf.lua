local group = vim.api.nvim_create_augroup('pdf.nvim', {})
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = '*.pdf',
  callback = function(ev)
    require('pdf').open(ev.buf)
  end,
})
-- a window resize or another window's text over the page
vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
  group = group,
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.b[vim.api.nvim_win_get_buf(win)].pdf then
        return require('pdf').redraw()
      end
    end
  end,
})
-- :PdfPosition {across} [{down}]: where pages sit (left/center/right,
-- top/center/bottom, or a fraction from 0 to 1)
vim.api.nvim_create_user_command('PdfPosition', function(o)
  require('pdf').position(o.fargs[1], o.fargs[2])
end, {
  nargs = '+',
  complete = function(_, line)
    local n = #vim.split(line, '%s+', { trimempty = true }) - (line:match('%s$') and 0 or 1)
    return n <= 1 and { 'left', 'center', 'right' } or { 'top', 'center', 'bottom' }
  end,
})
