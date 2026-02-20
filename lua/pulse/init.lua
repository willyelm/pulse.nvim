local config = require("pulse.config")
local picker = require("pulse.picker")

local M = {}

local MODE_PREFIX = {
  files = "",
  symbols = "@",
  workspace_symbols = "#",
  commands = ":",
}

local MODE_COMPLETIONS = { "files", "symbols", "workspace_symbols", "commands" }

local function open_panel(initial_prompt)
  local telescope_opts = config.options.telescope
  picker.open(vim.tbl_deep_extend("force", {
    initial_prompt = initial_prompt or "",
  }, telescope_opts))
end

local function pulse_command(opts)
  local mode = (opts and opts.args and opts.args ~= "") and opts.args or "files"
  local prefix = MODE_PREFIX[mode]
  if prefix == nil then
    vim.notify("Pulse: unknown mode '" .. tostring(mode) .. "'", vim.log.levels.ERROR)
    return
  end
  open_panel(prefix)
end

function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("Pulse", pulse_command, {
    nargs = "?",
    complete = function()
      return MODE_COMPLETIONS
    end,
  })

  if config.options.cmdline then
    vim.keymap.set("n", ":", function()
      open_panel(":")
    end, { noremap = true, silent = true, desc = "Pulse Cmdline" })
  end
end

return M
