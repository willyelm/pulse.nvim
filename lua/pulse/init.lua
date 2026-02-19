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
  if mode == "symbol" or mode == "symbols" then
    open_smart("@")
    return
  end
  if mode == "workspace_symbol" or mode == "workspace_symbols" then
    open_smart("#")
    return
  end
  if mode == "commands" then
    open_smart(":")
    return
  end

  vim.notify("Pulse: unknown mode '" .. mode .. "'", vim.log.levels.ERROR)
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
