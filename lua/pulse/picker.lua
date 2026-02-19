local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")

local common = require("pulse.pickers.common")
local files_picker = require("pulse.pickers.files")
local commands_picker = require("pulse.pickers.commands")
local symbols_picker = require("pulse.pickers.symbols")
local workspace_symbols_picker = require("pulse.pickers.workspace_symbols")

local M = {}

local modules = {
  files = files_picker,
  commands = commands_picker,
  symbol = symbols_picker,
  workspace_symbol = workspace_symbols_picker,
}

local kind_icons = {
  command = "",
  symbol = "󰙅",
  workspace_symbol = "󰘦",
}

local function close_existing_telescope_windows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) then
        local ft = vim.bo[buf].filetype
        if ft == "TelescopePrompt" or ft == "TelescopeResults" or ft == "TelescopePreview" then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
  end
end

local function devicon_for(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", "TelescopeResultsComment"
  end
  local name = vim.fn.fnamemodify(path, ":t")
  local ext = vim.fn.fnamemodify(path, ":e")
  local icon, hl = devicons.get_icon(name, ext, { default = true })
  return icon or "", hl or "TelescopeResultsComment"
end

local function entry_maker(item)
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
      { width = 28 },
    },
  })

  if item.kind == "header" then
    return {
      value = item,
      ordinal = item.label,
      kind = "header",
      display = function()
        return displayer({ { "", "Normal" }, { item.label, "Comment" }, { "", "Comment" } })
      end,
    }
  end

  if item.kind == "file" then
    local icon, icon_hl = devicon_for(item.path)
    local rel = vim.fn.fnamemodify(item.path, ":.")
    return {
      value = item,
      ordinal = rel,
      kind = "file",
      path = item.path,
      display = function()
        return displayer({ { icon, icon_hl }, { rel, "Normal" }, { "file", "Comment" } })
      end,
    }
  end

  if item.kind == "command" then
    return {
      value = item,
      ordinal = ":" .. item.command,
      kind = "command",
      display = function()
        return displayer({ { kind_icons.command, "TelescopeResultsIdentifier" }, { ":" .. item.command, "Normal" }, { item.source, "Comment" } })
      end,
    }
  end

  local filename = item.filename or ""
  local rel = filename ~= "" and vim.fn.fnamemodify(filename, ":.") or ""
  return {
    value = item,
    ordinal = ((item.kind == "workspace_symbol") and "#" or "@") .. " " .. string.format("%s %s %s", item.symbol or "", rel, item.container or ""),
    filename = filename,
    lnum = item.lnum,
    col = item.col,
    kind = item.kind,
    display = function()
      local icon = item.kind == "workspace_symbol" and kind_icons.workspace_symbol or kind_icons.symbol
      local right = rel
      if item.container and item.container ~= "" then
        right = item.container .. " " .. rel
      end
      return displayer({ { icon, "TelescopeResultsIdentifier" }, { item.symbol or "", "Normal" }, { right, "Comment" } })
    end,
  }
end

function M.open(opts)
  opts = opts or {}
  close_existing_telescope_windows()

  local picker_opts = vim.tbl_deep_extend("force", {
    layout_config = {
      width = 0.70,
      height = 0.45,
      prompt_position = "top",
      anchor = "N",
    },
    border = true,
  }, opts)

  local ok, themes = pcall(require, "telescope.themes")
  if ok and type(themes.get_dropdown) == "function" then
    picker_opts = themes.get_dropdown(picker_opts)
  end

  local picker
  local current_mode = "files"

  local function refresh_no_prompt_reset()
    if picker then
      pcall(picker.refresh, picker, picker.finder, { reset_prompt = false })
    end
  end

  local states = {
    files = modules.files.seed(vim.fn.getcwd()),
    commands = modules.commands.seed(),
    symbol = modules.symbol.seed({ on_update = refresh_no_prompt_reset }),
    workspace_symbol = modules.workspace_symbol.seed({ on_update = refresh_no_prompt_reset }),
  }

  states.workspace_symbol.on_update = refresh_no_prompt_reset

  local function build_items(prompt)
    local mode, query = common.parse_mode(prompt or "")
    current_mode = mode
    return modules[mode].items(states[mode], query)
  end

  picker = pickers.new(picker_opts, {
    prompt_title = modules.files.title(),
    results_title = false,
    finder = finders.new_dynamic({
      fn = function(prompt)
        local mode, _ = common.parse_mode(prompt or "")
        if picker and picker.prompt_title ~= modules[mode].title() then
          picker.prompt_title = modules[mode].title()
        end
        return build_items(prompt)
      end,
      entry_maker = entry_maker,
    }),
    sorter = conf.generic_sorter(picker_opts),
    previewer = false,
    initial_mode = picker_opts.initial_mode,
    prompt_prefix = picker_opts.prompt_prefix,
    selection_caret = picker_opts.selection_caret,
    entry_prefix = picker_opts.entry_prefix,
    layout_strategy = picker_opts.layout_strategy,
    layout_config = picker_opts.layout_config,
    sorting_strategy = picker_opts.sorting_strategy,
    border = picker_opts.border,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        if not selection or selection.kind == "header" then
          return
        end

        actions.close(prompt_bufnr)

        if selection.kind == "file" then
          vim.cmd.edit(vim.fn.fnameescape(selection.path))
          return
        end

        if selection.kind == "command" then
          local keys = vim.api.nvim_replace_termcodes(":" .. selection.value.command, true, false, true)
          vim.api.nvim_feedkeys(keys, "n", false)
          return
        end

        if selection.filename and selection.filename ~= "" then
          vim.cmd.edit(vim.fn.fnameescape(selection.filename))
        end
        if selection.lnum then
          vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
        end
      end)
      return true
    end,
  })

  if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
    picker:find({ default_text = picker_opts.initial_prompt })
  else
    picker:find()
  end
end

return M
