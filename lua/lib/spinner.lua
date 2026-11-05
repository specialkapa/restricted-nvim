-- "Something is in progress" animations, shared by every module that waits on a slow
-- process. Not loaded from init.lua: modules require it when they need it.
--
-- Styles:
--   braille  10 frames, one a second. For long waits measured in seconds to minutes
--            (a Hive query, a notebook cell), where the frame doubles as a seconds tick.
--   circle   a circle with a rotating filled quarter, 8 frames a second. For short waits
--            (IPython starting, a program running under the debugger), where a
--            once-a-second tick would look frozen.
--   ellipsis a growing "...", 3 steps a second, placed AFTER the text ("connecting...").
--            Plain ASCII, and cheap enough to redraw a whole panel with.
--   dots     one braille dot orbiting, 10 a second. Quieter than braille.
--   arc      a quarter arc sweeping round a circle, 10 a second.
--   pulse    a bar rising and falling, 12 a second. Reads as "working hard".
--   line     | / - \  ASCII only, for a terminal whose font lacks the others.
--
-- :lua require('lib.spinner').demo() shows them all, animated, in a float.
--
--   local spinner = require 'lib.spinner'
--   local started = vim.uv.hrtime()
--   local stop = spinner.tick(function()
--     ... redraw something showing spinner.label(started, 'running') ...
--   end)                              -- style defaults to 'circle'
--   stop()                            -- or return false from the callback
--
-- Frames are code points so the file stays ASCII (safe to retype by hand).

local M = {}

local uv = vim.uv or vim.loop

M.STYLES = {
  braille = {
    frames = { '\u{280B}', '\u{2819}', '\u{2839}', '\u{2838}', '\u{283C}', '\u{2834}', '\u{2826}', '\u{2827}', '\u{2807}', '\u{280F}' },
    interval = 1000,
  },
  circle = {
    frames = { '\u{25D0}', '\u{25D3}', '\u{25D1}', '\u{25D2}' }, -- black half: left, top, right, bottom
    interval = 125, -- each frame is a redraw, which matters in a browser terminal
  },
  ellipsis = { frames = { '   ', '.  ', '.. ', '...' }, interval = 333 },
  dots = {
    frames = { '\u{2801}', '\u{2802}', '\u{2804}', '\u{2840}', '\u{2880}', '\u{2820}', '\u{2810}', '\u{2808}' },
    interval = 100,
  },
  arc = { frames = { '\u{25DC}', '\u{25E0}', '\u{25DD}', '\u{25DE}', '\u{25E1}', '\u{25DF}' }, interval = 100 },
  pulse = {
    frames = { '\u{2581}', '\u{2582}', '\u{2583}', '\u{2584}', '\u{2585}', '\u{2586}', '\u{2587}', '\u{2588}',
      '\u{2587}', '\u{2586}', '\u{2585}', '\u{2584}', '\u{2583}', '\u{2582}' },
    interval = 80,
  },
  line = { frames = { '|', '/', '-', '\\' }, interval = 125 },
}

local function style_of(name)
  return M.STYLES[name or 'circle'] or error('spinner: unknown style ' .. tostring(name))
end

---Frame for a wait that began at `started` (from vim.uv.hrtime()). With no `started`
---(the wait has not really begun yet) it is the first frame.
function M.frame(started, style)
  local s = style_of(style)
  if not started then
    return s.frames[1]
  end
  local ms = (uv.hrtime() - started) / 1e6
  return s.frames[math.floor(ms / s.interval) % #s.frames + 1]
end

---Whole seconds since `started`; 0 without one.
function M.secs(started)
  return started and math.floor((uv.hrtime() - started) / 1e9) or 0
end

---"<frame> <text> 3s". The seconds only appear once the wait passes one second, so a
---quick wait never flashes "0s".
function M.label(started, text, style)
  local secs = M.secs(started)
  return M.frame(started, style) .. ' ' .. text .. (secs >= 1 and (' ' .. secs .. 's') or '')
end

---Call fn once per frame of `style` (on the main loop) until the returned stop() is
---called, or fn returns false.
function M.tick(fn, style)
  local t = uv.new_timer()
  local function stop()
    if not t:is_closing() then
      t:stop()
      t:close()
    end
  end
  t:start(
    0,
    style_of(style).interval,
    vim.schedule_wrap(function()
      if not t:is_closing() and fn() == false then
        stop()
      end
    end)
  )
  return stop
end

---Every style, animated side by side in a float. q or <Esc> closes it.
function M.demo()
  local names = vim.tbl_keys(M.STYLES)
  table.sort(names)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = 2,
    col = 4,
    width = 36,
    height = #names,
    style = 'minimal',
    border = 'rounded',
    title = ' lib.spinner ',
  })
  local started = uv.hrtime()
  local stop
  local function close()
    stop()
    pcall(vim.api.nvim_win_close, win, true)
  end
  stop = M.tick(function()
    if not vim.api.nvim_win_is_valid(win) then
      return false
    end
    local lines = {}
    for _, name in ipairs(names) do
      local s = M.STYLES[name]
      local f = M.frame(started, name)
      f = f .. string.rep(' ', 3 - vim.fn.strdisplaywidth(f)) -- ellipsis is 3 wide, the rest 1
      lines[#lines + 1] = ('  %-9s %s  %4d ms/frame'):format(name, f, s.interval)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end, 'pulse') -- the fastest style, so every one moves on time
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true })
  end
end

return M
