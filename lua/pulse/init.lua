local config = require("pulse.config")
local picker = require("pulse.picker")
local mode = require("pulse.mode")

local M = {}

local COMMAND_TO_MODE = {
  files = "files",
  symbols = "symbol",
  workspace_symbols = "workspace_symbol",
  commands = "commands",
  live_grep = "live_grep",
  fuzzy_search = "fuzzy_search",
  git_status = "git_status",
  diagnostics = "diagnostics",
}

local MODE_COMPLETIONS = vim.tbl_keys(COMMAND_TO_MODE)
table.sort(MODE_COMPLETIONS)

local function open_panel(initial_prompt, extra_opts)
  if vim.fn.getcmdwintype() ~= "" then
    vim.notify("Pulse: cannot open inside the command-line window", vim.log.levels.WARN)
    return
  end
  picker.open(vim.tbl_deep_extend("force", {
    initial_prompt = initial_prompt or "",
  }, config.options, extra_opts or {}))
end

local function setup_cmdline_replacement()
  local open_commands = function() open_panel(":") end
  local apply_cmdline_ui = function() vim.o.cmdheight = 0 end
  apply_cmdline_ui()

  vim.keymap.set({ "n", "x", "o" }, ":", open_commands, { noremap = true, silent = true, desc = "Pulse Cmdline" })
  vim.keymap.set("n", "q:", open_commands, { noremap = true, silent = true, desc = "Pulse Cmdline Window" })

  local group = vim.api.nvim_create_augroup("PulseCmdlineReplace", { clear = true })
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = apply_cmdline_ui,
  })
  vim.api.nvim_create_autocmd("CmdlineEnter", {
    group = group,
    pattern = ":",
    callback = function()
      vim.schedule(function()
        if vim.fn.mode() ~= "c" or vim.fn.getcmdtype() ~= ":" then
          return
        end
        local line = vim.fn.getcmdline()
        local esc = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
        vim.api.nvim_feedkeys(esc, "n", false)
        open_panel(":" .. line)
      end)
    end,
  })
end

local function pulse_command(opts)
  local name = (opts and opts.args and opts.args ~= "") and opts.args or "files"
  local internal = COMMAND_TO_MODE[name]
  if not internal then
    vim.notify("Pulse: unknown mode '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return
  end
  open_panel(mode.start(internal))
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
    setup_cmdline_replacement()
  end
end

return M
