local config = require("pulse.config")
local picker = require("pulse.picker")

local M = {}

local PREFIX_BY_MODE = {
  files = "",
  smart = "",
  symbol = "@",
  symbols = "@",
  workspace_symbol = "#",
  workspace_symbols = "#",
  commands = ":",
}

local function open_smart(initial_prompt)
  local t = config.options.telescope
  picker.open(vim.tbl_deep_extend("force", {
    mode = "smart",
    initial_prompt = initial_prompt or "",
  }, t))
end

local function pulse_command(opts)
  local mode = (opts and opts.args and opts.args ~= "") and opts.args or "smart"
  local prefix = PREFIX_BY_MODE[mode]

  if prefix == nil then
    vim.notify("Pulse: unknown mode '" .. mode .. "'", vim.log.levels.ERROR)
    return
  end

  open_smart(prefix)
end

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("Pulse", pulse_command, {
    nargs = "?",
    complete = function()
      return {
        "files",
        "symbol",
        "symbols",
        "workspace_symbol",
        "workspace_symbols",
        "commands",
        "smart",
      }
    end,
  })

  if config.options.cmdline then
    vim.keymap.set("n", ":", function()
      open_smart(":")
    end, { noremap = true, silent = true, desc = "Pulse Cmdline" })
  end
end

return M
