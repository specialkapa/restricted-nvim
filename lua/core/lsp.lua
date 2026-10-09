-- Python LSP, no plugins required.
--
-- Servers are started by hand with vim.lsp.start() -- no mason (nothing to download)
-- and no nvim-lspconfig (nothing to clone). Everything here is core Neovim.
--
-- Environment resolution handles three layouts, innermost first:
--   1. $VIRTUAL_ENV   a venv or poetry env -- wins whenever it is set
--   2. $CONDA_PREFIX  a conda env, which does NOT set VIRTUAL_ENV
--   3. $PATH          whatever is on it (e.g. a pipx shim)
-- With poetry nested inside conda, both are set and the poetry env correctly wins,
-- because that is where the project's packages actually live.

local is_win = vim.fn.has 'win32' == 1
local bin_dir = is_win and 'Scripts' or 'bin' -- .venv/bin on linux, .venv\Scripts on windows
local exe_ext = is_win and '.exe' or ''

local M = {}

---Root of the active Python environment, or nil. Conda envs use the same bin/ +
---lib/pythonX.Y/site-packages layout as a venv, so everything downstream treats them
---identically.
local function env_root()
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= '' then
    return vim.fs.normalize(venv), 'venv'
  end
  local conda = vim.env.CONDA_PREFIX
  if conda and conda ~= '' then
    return vim.fs.normalize(conda), 'conda'
  end
  return nil, nil
end

---Absolute path to `name`, preferring the active environment over PATH. nil if absent.
---Returning a full path keeps libuv from having to guess at PATHEXT on Windows.
local function resolve(name)
  local root = env_root()
  if root then
    local p = vim.fs.normalize(root .. '/' .. bin_dir .. '/' .. name .. exe_ext)
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  local found = vim.fn.exepath(name)
  return found ~= '' and found or nil
end

---The interpreter a server should analyse against, or nil if no environment is active.
local function venv_python()
  local root = env_root()
  if not root then
    return nil
  end
  for _, name in ipairs { 'python', 'python3' } do
    local p = vim.fs.normalize(root .. '/' .. bin_dir .. '/' .. name .. exe_ext)
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return nil
end

---Environment handed to the language servers.
---ty discovers the interpreter from $VIRTUAL_ENV. A conda env does not set it, so
---point it at $CONDA_PREFIX -- the directory layout is the same, so discovery works.
local function server_env()
  local root, kind = env_root()
  if root and kind == 'conda' then
    return { VIRTUAL_ENV = root }
  end
  return nil
end

M.resolve = resolve
M.venv_python = venv_python
M.env_root = env_root

local root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', '.git' }

local function root_dir(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  local start = fname ~= '' and vim.fs.dirname(fname) or vim.fn.getcwd()
  local found = vim.fs.find(root_markers, { upward = true, path = start })[1]
  return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

-- Set to true to run python-lsp-server instead of ty.
local USE_PYLSP = false

local function configs_for(bufnr)
  local root = root_dir(bufnr)
  local cmd_env = server_env()
  local out = {}

  -- ruff: diagnostics, quick fixes, import sorting, formatting.
  -- `ruff server` is built into ruff itself (>= 0.5.3); ruff-lsp is the legacy fallback.
  local ruff = resolve 'ruff'
  local ruff_lsp = resolve 'ruff-lsp'
  if ruff then
    out[#out + 1] = { name = 'ruff', cmd = { ruff, 'server' }, root_dir = root, cmd_env = cmd_env }
  elseif ruff_lsp then
    out[#out + 1] = { name = 'ruff_lsp', cmd = { ruff_lsp }, root_dir = root, cmd_env = cmd_env }
  end

  if USE_PYLSP then
    local pylsp = resolve 'pylsp'
    if pylsp then
      out[#out + 1] = {
        name = 'pylsp',
        cmd = { pylsp },
        root_dir = root,
        cmd_env = cmd_env,
        settings = {
          pylsp = {
            plugins = {
              -- Point jedi at the environment's interpreter so it sees installed
              -- packages even when pylsp itself lives elsewhere.
              jedi = { environment = venv_python() },
              -- ruff already covers these; leaving them on duplicates diagnostics.
              pycodestyle = { enabled = false },
              pyflakes = { enabled = false },
              mccabe = { enabled = false },
              autopep8 = { enabled = false },
              yapf = { enabled = false },
            },
          },
        },
      }
    end
  else
    -- ty: type checking, hover, goto-definition, completion.
    local ty = resolve 'ty'
    if ty then
      out[#out + 1] = { name = 'ty', cmd = { ty, 'server' }, root_dir = root, cmd_env = cmd_env }
    end
  end

  return out
end

local warned = false

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('python-lsp', { clear = true }),
  pattern = 'python',
  callback = function(args)
    local cfgs = configs_for(args.buf)
    if #cfgs == 0 and not warned then
      warned = true
      vim.notify('no python language server found in the active environment or on PATH', vim.log.levels.WARN)
      return
    end
    for _, cfg in ipairs(cfgs) do
      -- vim.lsp.start reuses a client with the same name+root+cmd, so this is safe to
      -- call for every python buffer you open.
      vim.lsp.start(cfg, { bufnr = args.buf })
    end
  end,
})

vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('python-lsp-attach', { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not client then
      return
    end

    -- ruff's hover is just the rule text and it wins the race against ty's type info.
    if client.name == 'ruff' or client.name == 'ruff_lsp' then
      client.server_capabilities.hoverProvider = false
    end

    -- Native completion (0.11+). On older builds vim.lsp.start has already set
    -- 'omnifunc', so <C-x><C-o> works regardless.
    if vim.lsp.completion and vim.lsp.completion.enable then
      pcall(vim.lsp.completion.enable, true, client.id, args.buf, { autotrigger = true })
    end

    local map = function(keys, fn, desc)
      vim.keymap.set('n', keys, fn, { buffer = args.buf, desc = 'LSP: ' .. desc })
    end

    map('gd', vim.lsp.buf.definition, 'Goto definition')
    -- In the picker rather than the quickfix window: previews and split/tab opens.
    map('gr', function()
      require('core.picker').references()
    end, 'Goto references')
    map('K', vim.lsp.buf.hover, 'Hover documentation')
    map('<leader>rn', vim.lsp.buf.rename, 'Rename')
    map('<leader>ca', vim.lsp.buf.code_action, 'Code action')
    map('<leader>f', function()
      vim.lsp.buf.format { async = true }
    end, 'Format buffer')
    map('<leader>ri', function()
      vim.lsp.buf.code_action {
        context = { only = { 'source.organizeImports' }, diagnostics = {} },
        apply = true,
      }
    end, 'Ruff organize imports')
  end,
})

vim.diagnostic.config {
  virtual_text = true,
  severity_sort = true,
  float = { border = 'single', source = true },
}

-- Reports which environment the servers resolved against -- the first thing to check
-- when completion or type errors look wrong.
vim.api.nvim_create_user_command('PyEnv', function()
  local root, kind = env_root()
  print(('env : %s (%s)'):format(root or 'none', kind or 'PATH only'))
  print(('py  : %s'):format(venv_python() or vim.fn.exepath 'python'))
  print(('ruff: %s'):format(resolve 'ruff' or 'not found'))
  print(('ty  : %s'):format(resolve 'ty' or 'not found'))
end, { desc = 'Show the Python environment the LSP resolved' })

return M
