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
