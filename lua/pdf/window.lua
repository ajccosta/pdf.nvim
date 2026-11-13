-- A PDF's window: its options, and nvim's cursor hidden over it.
local W = {}

-- The options a PDF's window has, so all its columns are the page's; and
-- one look, current or not: nvim repaints a window whose NormalNC differs
-- (a colorscheme's link to Normal does) as it gains or loses focus, and the
-- terminal drops the image under its cells.
W.pdf_window = {
  number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0',
  colorcolumn = '', cursorline = false, cursorcolumn = false,
  winhighlight = 'Normal:Normal,NormalNC:Normal',
}

-- window_options(pdf): give the current window a PDF's options, keeping what
-- it had; or, pdf false, give it back what it had. Window options go with the
-- window, not the buffer, so the next file in it would have them too.
function W.window_options(pdf)
  local saved = vim.w.pdf_saved
  if pdf then
    if not saved then
      saved = {}
      for name in pairs(W.pdf_window) do
        saved[name] = vim.wo[name]
      end
      vim.w.pdf_saved = saved
    end
    for name, value in pairs(W.pdf_window) do
      vim.wo[0][0][name] = value
    end
  elseif saved then
    for name, value in pairs(saved) do
      vim.wo[0][0][name] = value
    end
    vim.w.pdf_saved = nil
  end
end

-- hide_cursor(hide): hide nvim's own cursor (in Normal and Visual mode), the
-- page's text cursor being the one that counts over a PDF; or show it again.
local guicursor
function W.hide_cursor(hide)
  if hide and not guicursor then
    vim.api.nvim_set_hl(0, 'PdfHiddenCursor', { blend = 100, bg = '#000000', default = true })
    guicursor = vim.o.guicursor
    vim.o.guicursor = guicursor .. ',n-v:PdfHiddenCursor'
  elseif not hide and guicursor then
    vim.o.guicursor, guicursor = guicursor, nil
  end
end

return W
