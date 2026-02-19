local config = require("pulse.config")
local picker = require("pulse.picker")

local M = {}

local function open_smart(initial_prompt)
  local t = config.options.telescope
  picker.open(vim.tbl_deep_extend("force", {
    mode = "smart",
    initial_prompt = initial_prompt or "",
  }, t))
end

local function pulse_command(opts)
  local mode = "smart"
  if opts and opts.args and opts.args ~= "" then
    mode = opts.args
  end

  if mode == "smart" or mode == "files" then
    open_smart("")
    return
  end
  if mode == "symbol" then
    open_smart("@")
    return
  end
  if mode == "workspace_symbol" then
    open_smart("#")
    return
  end
  if mode == "commands" then
    open_smart(":")
    return
  end

  vim.notify("Pulse: unknown mode '" .. mode .. "'", vim.log.levels.ERROR)
end

function M.files()
  open_smart("")
end

function M.commands()
  open_smart(":")
end

function M.workspace_symbol()
  open_smart("#")
end

function M.symbol()
  open_smart("@")
end

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("Pulse", pulse_command, {
    nargs = "?",
    complete = function()
      return { "files", "symbol", "workspace_symbol", "commands", "smart" }
    end,
  })

  local km = config.options.keymaps or {}
  if km.open and km.open ~= "" then
    vim.keymap.set("n", km.open, M.files, { desc = "Pulse" })
  end
  if km.commands and km.commands ~= "" then
    vim.keymap.set("n", km.commands, M.commands, { desc = "Pulse Commands" })
  end
  if km.workspace_symbol and km.workspace_symbol ~= "" then
    vim.keymap.set("n", km.workspace_symbol, M.workspace_symbol, { desc = "Pulse Workspace Symbols" })
  end
  if km.symbol and km.symbol ~= "" then
    vim.keymap.set("n", km.symbol, M.symbol, { desc = "Pulse Symbols" })
  end

  if config.options.cmdline then
    vim.keymap.set("n", ":", function()
      M.commands()
    end, { noremap = true, silent = true, desc = "Pulse Cmdline" })
  end
end

return M
