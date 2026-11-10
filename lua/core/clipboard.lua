-- Clipboard provider for machines with no xclip / wl-copy / win32yank.
--
-- Neovim does not talk to the system clipboard itself; it shells out to a helper, and
-- reports `has('clipboard') == 0` when it cannot find one. Nothing here needs to be
-- installed -- each branch uses something the platform already ships.
--
--   Windows  clip.exe to copy (a Windows built-in, instant) and PowerShell's
--            Get-Clipboard to paste. PowerShell is slow to start, so it is used only on
--            the paste path, which is the rarer direction.
--   WSL      the same, since the Windows binaries are on PATH.
--   Linux    OSC 52 -- an escape sequence that asks the TERMINAL to set its own
--            clipboard. Works over SSH with no tools at all, which is the only option on
--            a headless enterprise box. Copy is widely supported; paste usually is not
--            (terminals refuse it for security), so paste falls back to Neovim's own
--            registers.
--
-- Loaded before anything that yanks. Does nothing at all when a real provider exists.

-- Set to true to make every yank/put use the system clipboard without needing "+.
local UNNAMED = false

local function have(cmd)
  return vim.fn.executable(cmd) == 1
end

local function setup()
  -- A working provider already? Leave it alone.
  if vim.fn.has('clipboard') == 1 and vim.g.clipboard == nil then
    return 'built-in'
  end

  local is_win = vim.fn.has('win32') == 1
  local is_wsl = vim.fn.has('wsl') == 1

  if (is_win or is_wsl) and have('clip.exe') then
    -- Get-Clipboard emits CRLF; strip the CR or every pasted line gains a ^M.
    local paste = {
      'powershell.exe',
      '-NoProfile',
      '-NoLogo',
      '-Command',
      '[Console]::Out.Write($(Get-Clipboard -Raw).tostring().replace("`r`n","`n"))',
    }
    vim.g.clipboard = {
      name = 'clip.exe + powershell',
      copy = { ['+'] = { 'clip.exe' }, ['*'] = { 'clip.exe' } },
      paste = { ['+'] = paste, ['*'] = paste },
      cache_enabled = true, -- avoid re-invoking powershell for a paste we just copied
    }
    return 'clip.exe + powershell'
  end

  -- OSC 52: the terminal owns the clipboard, so nothing needs installing. Works over
  -- SSH. Paste is left to Neovim's registers because most terminals refuse OSC 52 reads.
  local ok, osc52 = pcall(require, 'vim.ui.clipboard.osc52')
  if ok then
    -- Since the terminal can't be read back, + and * remember what was last copied into
    -- them. Falling back to `"` here was wrong: setreg('+', x) points `p` at +, and +
    -- then answered with `"`, which still held the PREVIOUS yank.
    local last = {}
    local function copy(reg)
      local send = osc52.copy(reg)
      return function(lines, regtype)
        last[reg] = { lines, regtype }
        send(lines, regtype)
      end
    end
    local function paste(reg)
      return function()
        return last[reg] or vim.split(vim.fn.getreg('0'), '\n')
      end
    end
    vim.g.clipboard = {
      name = 'OSC 52',
      copy = { ['+'] = copy('+'), ['*'] = copy('*') },
      paste = { ['+'] = paste('+'), ['*'] = paste('*') },
    }
    return 'OSC 52 (copy only)'
  end

  return nil
end

local provider = setup()

if provider and UNNAMED then
  vim.opt.clipboard = 'unnamedplus'
end

-- :ClipboardStatus -- what got wired up, and whether it works.
vim.api.nvim_create_user_command('ClipboardStatus', function()
  local g = vim.g.clipboard
  print('provider   : ' .. (g and g.name or (vim.fn.has('clipboard') == 1 and 'built-in' or 'NONE')))
  print("has('clipboard') : " .. vim.fn.has('clipboard'))
  print('clipboard opt    : ' .. (vim.o.clipboard == '' and '(unset -- use "+y explicitly)' or vim.o.clipboard))
  for _, t in ipairs({ 'xclip', 'xsel', 'wl-copy', 'win32yank.exe', 'clip.exe', 'powershell.exe', 'pbcopy' }) do
    print(('  %-16s %s'):format(t, have(t) and vim.fn.exepath(t) or '-'))
  end
end, { desc = 'Show the resolved clipboard provider' })

return { provider = provider }
