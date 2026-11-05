-- Brief highlights that fade out: "this just changed" without leaving anything behind.
-- Not loaded from init.lua: modules require it when they need it.
--
--   local fade = require 'lib.fade'
--   fade.lines(buf, { { 3, 5 }, { 10, 10 } })        -- rows 3-5 and 10 (1-based), bg fades
--   local group = fade.group({ from = 'DiagnosticOk', to = 'NotebookBorder', attr = 'fg',
--                              on_done = function() ... stop using `group` ... end })
--
-- How: each fade gets its own highlight group, and a timer redefines that group a few
-- times, blending from the start colour to the end colour. Changing a group's colour
-- redraws everything using it, so nothing has to be re-rendered by the caller.
--
-- Without 'termguicolors' colours cannot be blended: the highlight is shown unchanged for
-- the whole duration, then removed.

local M = {}

local uv = vim.uv or vim.loop

M.STEPS = 6 -- colour changes per fade; each is a redraw, so keep it small for slow terminals
M.HOLD = 150 -- ms at full colour before fading starts
M.DURATION = 600 -- ms of fading after that

local ns = vim.api.nvim_create_namespace('lib.fade')
local seq = 0

---24-bit colour of `attr` ('fg' or 'bg') in highlight group `name`, following links.
local function color(name, attr)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl[attr] or nil
end

---The editor background, guessing from 'background' when the theme leaves it unset.
local function normal_bg()
  return color('Normal', 'bg') or (vim.o.background == 'light' and 0xffffff or 0x000000)
end

---A colour: a number already, or a group name read for `attr` (falling back to its other
---attribute, so a fg-only group still gives a colour for a bg fade).
local function resolve(c, attr)
  if type(c) == 'number' then
    return c
  end
  if type(c) == 'string' then
    return color(c, attr) or color(c, attr == 'fg' and 'bg' or 'fg')
  end
end

local function mix(a, b, t)
  local function ch(shift)
    local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
    return bit.lshift(math.floor(x + (y - x) * t + 0.5), shift)
  end
  return ch(16) + ch(8) + ch(0)
end

---Make a highlight group that starts at `spec.from` and fades to `spec.to`.
---spec: from, to (colour numbers or group names), attr ('fg' default, or 'bg'),
---hold, duration (ms), on_done (called once the fade is over). Returns the group name.
function M.group(spec)
  local attr = spec.attr or 'fg'
  local hold, duration = spec.hold or M.HOLD, spec.duration or M.DURATION
  seq = seq % 32 + 1 -- a small pool of names; a fade lasts well under a second
  local name = 'LibFade' .. seq

  local from = resolve(spec.from, attr)
  local to = resolve(spec.to, attr) or (attr == 'bg' and normal_bg() or color('Normal', 'fg'))
  if not (from and vim.o.termguicolors) then
    -- No colours to blend: show the start group as it is, for the whole time.
    vim.api.nvim_set_hl(0, name, type(spec.from) == 'string' and { link = spec.from } or {})
    vim.defer_fn(function()
      if spec.on_done then
        spec.on_done()
      end
    end, hold + duration)
    return name
  end

  vim.api.nvim_set_hl(0, name, { [attr] = from })
  local step = 0
  local t = uv.new_timer()
  t:start(
    hold,
    math.floor(duration / M.STEPS),
    vim.schedule_wrap(function()
      if t:is_closing() then
        return
      end
      step = step + 1
      if step >= M.STEPS then
        t:stop()
        t:close()
        if spec.on_done then
          spec.on_done()
        end
        return
      end
      vim.api.nvim_set_hl(0, name, { [attr] = mix(from, to, step / M.STEPS) })
    end)
  )
  return name
end

---Flash whole lines of `buf`: ranges are { first, last } pairs, 1-based and inclusive.
---opts.color: the group whose background to start from (default 'DiffText').
function M.lines(buf, ranges, opts)
  opts = opts or {}
  if #ranges == 0 or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local ids = {}
  local group = M.group({
    from = opts.color or 'DiffText',
    attr = 'bg',
    hold = opts.hold,
    duration = opts.duration,
    on_done = function()
      for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
      end
    end,
  })
  local count = vim.api.nvim_buf_line_count(buf)
  for _, r in ipairs(ranges) do
    local first, last = math.max(r[1], 1), math.min(r[2], count)
    if first <= last then
      ids[#ids + 1] = vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
        end_row = last,
        end_col = 0,
        hl_group = group,
        hl_eol = true,
        priority = 5000, -- above syntax, semantic tokens and diagnostics
        strict = false,
      })
    end
  end
end

return M
