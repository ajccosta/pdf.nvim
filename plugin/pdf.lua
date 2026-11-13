local group = vim.api.nvim_create_augroup('pdf.nvim', {})
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = '*.pdf',
  callback = function(ev)
    require('pdf').open(ev.buf)
  end,
})
-- another file in a window that had a PDF: the window's own options back; a
-- window split from a PDF's keeps what the PDF's had to give back
vim.api.nvim_create_autocmd('BufWinEnter', {
  group = group,
  callback = function(ev)
    if not vim.b[ev.buf].pdf then
      require('pdf').window_options(false)
      require('pdf').unnote(vim.api.nvim_get_current_win())
      require('pdf').clear(vim.api.nvim_get_current_win())
    end
  end,
})
vim.api.nvim_create_autocmd('WinClosed', {
  group = group,
  callback = function(ev)
    if package.loaded.pdf then
      vim.schedule(function()
        require('pdf').unnote(tonumber(ev.match))
        require('pdf').clear(tonumber(ev.match))
      end)
    end
  end,
})
-- each open PDF's view, to open it there next time; and the cursor back, or
-- the shell's stays hidden (quitting from a PDF leaves no BufLeave)
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    if package.loaded.pdf then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        require('pdf').keep_view(buf)
      end
      require('pdf').hide_cursor(false)
      require('pdf').clear()
    end
  end,
})
-- another tab: its pages gone, where the terminal keeps them until told
vim.api.nvim_create_autocmd('TabLeave', {
  group = group,
  callback = function()
    if package.loaded.pdf then
      require('pdf').clear()
    end
  end,
})
-- CTRL-Z: the shell's cursor while suspended, hidden again on the way back
vim.api.nvim_create_autocmd({ 'VimSuspend', 'VimResume' }, {
  group = group,
  callback = function(ev)
    if package.loaded.pdf then
      require('pdf').hide_cursor(ev.event == 'VimResume' and vim.b.pdf ~= nil)
      -- out to the terminal before nvim stops
      vim.cmd.redraw()
    end
  end,
})
vim.api.nvim_create_autocmd('WinNew', {
  group = group,
  callback = function()
    local prev = vim.fn.win_getid(vim.fn.winnr('#'))
    if vim.b.pdf and vim.w[prev].pdf_saved then
      vim.w.pdf_saved = vim.w[prev].pdf_saved
    end
    -- a split of a PDF's window (CTRL-W v) is for something else beside it:
    -- an empty buffer, unless the split was given a file (:vsplit notes.md)
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    if vim.b.pdf and require('pdf').config.split_empty then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          vim.api.nvim_win_call(win, function() vim.cmd.enew() end)
        end
      end)
    end
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
  nargs = '*',
  complete = function(_, line)
    local n = #vim.split(line, '%s+', { trimempty = true }) - (line:match('%s$') and 0 or 1)
    return n <= 1 and { 'left', 'center', 'right' } or { 'top', 'center', 'bottom' }
  end,
})
-- :PdfColor {name|#rrggbb}: the colour new comments get
vim.api.nvim_create_user_command('PdfColor', function(o)
  require('pdf').set_color(o.fargs[1])
end, {
  nargs = '?',
  complete = function()
    local names = vim.tbl_keys(require('pdf').config.colors)
    table.sort(names)
    return names
  end,
})
-- :PdfComments: open or close the PDF's comments list
vim.api.nvim_create_user_command('PdfComments', function()
  require('pdf').comments()
end, {})
-- :PdfExport [file]: the comments as text, "{highlighted text}: {comment}"
vim.api.nvim_create_user_command('PdfExport', function(o)
  require('pdf').export(o.args)
end, { nargs = '?', complete = 'file' })
