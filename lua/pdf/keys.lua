-- What each key does (config.keys names the action), mapped in a PDF's
-- buffer; the mouse's everywhere, acting on the PDF under it.
local comments = require('pdf.comments')
local config = require('pdf.config')
local cursor = require('pdf.cursor')
local mouse = require('pdf.mouse')
local view = require('pdf.view')
local A = {}

local function scroller(dx, dy, step)
  return function()
    local n = vim.v.count1
    view.scroll(dx * n, dy * n, config[step])
  end
end

local actions = {
  next = function() view.go(vim.b.pdf.page + 1 + vim.v.count1) end,
  prev = function() view.go(vim.b.pdf.page + 1 - vim.v.count1) end,
  visual = function() cursor.visual(false) end,
  visual_lines = function() cursor.visual(true) end,
  yank = function() cursor.yank() end,
  find = function() cursor.find('f') end,
  find_back = function() cursor.find('F') end,
  till = function() cursor.find('t') end,
  till_back = function() cursor.find('T') end,
  find_next = function() cursor.find_again(false) end,
  find_prev = function() cursor.find_again(true) end,
  jump_back = function() cursor.jump(vim.v.count1) end,
  jump_forward = function() cursor.jump(-vim.v.count1) end,
  edit_click = function() comments.edit_click() end,
  scroll_down = scroller(0, 1, 'scroll'),
  scroll_up = scroller(0, -1, 'scroll'),
  half_down = scroller(0, 1, 'half'),
  half_up = scroller(0, -1, 'half'),
  scroll_left = scroller(-1, 0, 'scroll'),
  scroll_right = scroller(1, 0, 'scroll'),
  wheel_down = scroller(0, 1, 'wheel'),
  wheel_up = scroller(0, -1, 'wheel'),
  wheel_left = scroller(-1, 0, 'wheel'),
  wheel_right = scroller(1, 0, 'wheel'),
  zoom_in = function() view.zoom(config.zoom ^ vim.v.count1) end,
  zoom_out = function() view.zoom(config.zoom ^ -vim.v.count1) end,
  fit = function() view.zoom() end,
  fit_width = function() view.fit_width() end,
  point = function(m) mouse.point(m) end,
  drag = function(m) mouse.drag(m) end,
  release = function() end,
  clear = function() comments.forget(vim.api.nvim_get_current_buf()) end,
  comment = function() cursor.comment() end,
  delete = function() comments.delete() end,
  comments = function() comments.comments() end,
  margin = function() view.margin() end,
}

for action, motion in pairs(cursor.motions) do
  actions[action] = function() cursor.move(motion, vim.v.count) end
end

-- The actions that act on the window under the mouse, not the current one:
-- their keys are mapped everywhere, and do what they did before elsewhere.
-- pass: over a PDF too the key still does its own (a click goes to the
-- window), and the action after. press: the button goes down, so held ones
-- (a drag, until release) go to that window wherever the mouse is.
A.mouse_actions = {
  wheel_down = {}, wheel_up = {}, wheel_left = {}, wheel_right = {},
  point = { pass = true, press = true },
  drag = { held = true },
  release = { held = true, release = true },
  edit_click = { press = true },
}

local held -- the PDF window the button went down in, until it comes up

local mouse_mapped = false

local function map_mouse()
  if mouse_mapped then
    return
  end
  mouse_mapped = true
  for action in pairs(A.mouse_actions) do
    for _, key in ipairs(config.keys[action] or {}) do
      vim.keymap.set({ 'n', 'v', 'i' }, key, function()
        local spec, m = A.mouse_actions[action], vim.fn.getmousepos()
        local win = m.winid
        if spec.held then
          win = held
          held = not spec.release and held or nil
          if not win then
            return key
          end
        elseif win == 0 or not vim.b[vim.api.nvim_win_get_buf(win)].pdf then
          return key
        elseif spec.press then
          held = win
        end
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_call(win, function() actions[action](m) end)
          end
        end)
        return spec.pass and key or ''
      end, { expr = true, replace_keycodes = true, desc = 'pdf.nvim: ' .. action .. ' under the mouse' })
    end
  end
end

-- map(buf): buf's keys, and the mouse's.
function A.map(buf)
  for action, keys in pairs(config.keys) do
    if not A.mouse_actions[action] then
      for _, key in ipairs(keys) do
        if key:match('^%d$') then
          -- a digit after a count is the count's (10j), as in Vim
          vim.keymap.set('n', key, function()
            if vim.v.count > 0 then
              return key
            end
            vim.schedule(actions[action])
            return ''
          end, { buffer = buf, nowait = true, expr = true })
        else
          vim.keymap.set('n', key, actions[action], { buffer = buf, nowait = true })
        end
      end
    end
  end
  map_mouse()
end

A.actions = actions

return A
