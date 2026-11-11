-- A paste into a PDF's window (a middle click, a PDF dropped on it): a PDF's
-- path opens that PDF, anything else is dropped, as the page takes no text.
-- iTerm pastes a copy of the page's image when a click drags it a little.
local paste, pasted = vim.paste, ''
vim.paste = function(lines, phase)
  if not vim.b.pdf then
    return paste(lines, phase)
  end
  pasted = (phase == -1 or phase == 1) and '' or pasted
  pasted = pasted .. table.concat(lines, '\n')
  if phase == -1 or phase == 3 then
    local path = vim.trim(pasted):gsub([[^(['"])(.*)%1$]], '%2'):gsub('\\(.)', '%1')
    if path:lower():match('%.pdf$') and vim.fn.filereadable(vim.fn.expand(path)) == 1 then
      vim.cmd.edit(vim.fn.fnameescape(vim.fn.expand(path)))
    end
  end
  return true
end
