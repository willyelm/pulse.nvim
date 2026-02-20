local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local sorters = require("telescope.sorters")

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
  Command = "", File = "󰈔", Module = "󰆧", Namespace = "󰌗", Package = "󰏗", Class = "󰠱",
  Method = "󰆧", Property = "󰆼", Field = "󰆼", Constructor = "󰆧", Enum = "󰕘", Interface = "󰕘",
  Function = "󰊕", Variable = "󰀫", Constant = "󰏿", String = "󰀬", Number = "󰎠", Boolean = "󰨙",
  Array = "󰅪", Object = "󰅩", Key = "󰌋", Null = "󰟢", EnumMember = "󰕘", Struct = "󰙅",
  Event = "󱐋", Operator = "󰆕", TypeParameter = "󰬛", Symbol = "󰘧",
}

local symbol_kind_hl = {
  File = "Directory", Module = "Include", Namespace = "Include", Package = "Include", Class = "Type",
  Method = "Function", Property = "Identifier", Field = "Identifier", Constructor = "Function", Enum = "Type",
  Interface = "Type", Function = "Function", Variable = "Identifier", Constant = "Constant", String = "String",
  Number = "Number", Boolean = "Boolean", Array = "Type", Object = "Type", Key = "Identifier",
  Null = "Constant", EnumMember = "Constant", Struct = "Type", Event = "PreProc", Operator = "Operator",
  TypeParameter = "Type", Symbol = "Identifier",
}

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft or ft == "" then
    ft = vim.fn.fnamemodify(path, ":e")
  end
  if not ft or ft == "" then
    ft = "file"
  end
  return ft
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

local function kind_hl(kind)
  local pulse_hl = "Pulse" .. tostring(kind or "Symbol")
  if vim.fn.hlexists(pulse_hl) == 1 then
    return pulse_hl
  end
  return symbol_kind_hl[kind] or "Identifier"
end

local function symbol_parts(item)
  local kind = item.symbol_kind_name or "Symbol"
  local icon = kind_icons[kind] or kind_icons.Symbol
  local hl = kind_hl(kind)
  local indent = string.rep("  ", math.max(item.depth or 0, 0))
  return indent, icon, item.symbol or "", kind, hl
end

local function make_entry_maker()
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 2 },
      { remaining = true },
      { width = 22 },
    },
  })

  return function(item)
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
          return displayer({ { icon, icon_hl }, { rel, "Normal" }, { filetype_for(item.path), "Comment" } })
        end,
      }
    end

    if item.kind == "command" then
      return {
        value = item,
        ordinal = ":" .. item.command,
        kind = "command",
        display = function()
          return displayer({
            { kind_icons.Command, "TelescopeResultsIdentifier" },
            { ":" .. item.command, "Normal" },
            { item.source, "Comment" },
          })
        end,
      }
    end

    local filename = item.filename or ""
    local rel = filename ~= "" and vim.fn.fnamemodify(filename, ":.") or ""
    local indent, icon, name, kind, kind_hl = symbol_parts(item)

    return {
      value = item,
      ordinal = ((item.kind == "workspace_symbol") and "#" or "@")
        .. " " .. string.format("%s %s %s", item.symbol or "", rel, item.container or ""),
      filename = filename,
      lnum = item.lnum,
      col = item.col,
      kind = item.kind,
      display = function()
        local right = kind
        if item.kind == "workspace_symbol" and item.container and item.container ~= "" then
          right = kind .. "  " .. item.container
        end
        return displayer({ { icon, kind_hl }, { indent .. name, "Normal" }, { right, "Comment" } })
      end,
    }
  end
end

local function jump_to_selection(selection)
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
end

local function move_until_selectable(prompt_bufnr, step)
  local guard = 0
  repeat
    step(prompt_bufnr)
    guard = guard + 1
    local selected = action_state.get_selected_entry()
    if not selected or selected.kind ~= "header" then
      break
    end
  until guard > 200
end

local function set_results_winhl(prompt_bufnr)
  vim.schedule(function()
    local p = action_state.get_current_picker(prompt_bufnr)
    if p and p.results_win and vim.api.nvim_win_is_valid(p.results_win) then
      vim.api.nvim_set_option_value("winhl", "Normal:Normal,CursorLine:CursorLine", { win = p.results_win })
    end
  end)
end

function M.open(opts)
  opts = opts or {}
  local picker_opts = vim.tbl_deep_extend("force", {
    layout_config = { width = 0.70, height = 0.45, prompt_position = "top", anchor = "N" },
    border = true,
  }, opts)

  local ok, themes = pcall(require, "telescope.themes")
  if ok and type(themes.get_dropdown) == "function" then
    picker_opts = themes.get_dropdown(picker_opts)
  end

  local entry_maker = make_entry_maker()
  local picker

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

  local function build_items(prompt)
    prompt = prompt or ""
    if vim.startswith(prompt, ":") then
      return modules.commands.items(states.commands, prompt:sub(2)), "commands"
    end
    if vim.startswith(prompt, "#") then
      return modules.workspace_symbol.items(states.workspace_symbol, prompt:sub(2)), "workspace_symbol"
    end
    if vim.startswith(prompt, "@") then
      return modules.symbol.items(states.symbol, prompt:sub(2)), "symbol"
    end
    return modules.files.items(states.files, prompt), "files"
  end

  picker = pickers.new(picker_opts, {
    prompt_title = modules.files.title(),
    results_title = false,
    finder = finders.new_dynamic({
      fn = function(prompt)
        local items, mode = build_items(prompt)
        local new_title = modules[mode].title()
        if picker and picker.prompt_title ~= new_title then
          picker.prompt_title = new_title
          if picker.prompt_border and picker.prompt_border.change_title then
            pcall(picker.prompt_border.change_title, picker.prompt_border, new_title)
          end
        end
        return items
      end,
      entry_maker = entry_maker,
    }),
    sorter = sorters.empty(),
    previewer = false,
    initial_mode = picker_opts.initial_mode,
    prompt_prefix = picker_opts.prompt_prefix,
    selection_caret = picker_opts.selection_caret,
    entry_prefix = picker_opts.entry_prefix,
    layout_strategy = picker_opts.layout_strategy,
    layout_config = picker_opts.layout_config,
    sorting_strategy = picker_opts.sorting_strategy,
    border = picker_opts.border,
    attach_mappings = function(prompt_bufnr, map)
      set_results_winhl(prompt_bufnr)

      local function move_next()
        move_until_selectable(prompt_bufnr, actions.move_selection_next)
      end

      local function move_prev()
        move_until_selectable(prompt_bufnr, actions.move_selection_previous)
      end

      local function preview_selection()
        local selection = action_state.get_selected_entry()
        if not selection then
          return
        end

        if selection.kind == "header" then
          move_next()
          return
        end

        if selection.kind == "symbol" or selection.kind == "workspace_symbol" or selection.kind == "file" then
          local p = action_state.get_current_picker(prompt_bufnr)
          local target_win = p and p.original_win_id or nil
          if not target_win or not vim.api.nvim_win_is_valid(target_win) then
            return
          end

          vim.api.nvim_win_call(target_win, function()
            jump_to_selection(selection)
          end)
        end
      end

      map("i", "<Down>", move_next)
      map("i", "<C-n>", move_next)
      map("i", "<Up>", move_prev)
      map("i", "<C-p>", move_prev)
      map("n", "j", move_next)
      map("n", "<Down>", move_next)
      map("n", "k", move_prev)
      map("n", "<Up>", move_prev)
      map("i", "<Tab>", preview_selection)
      map("n", "<Tab>", preview_selection)

      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        if not selection or selection.kind == "header" then
          return
        end
        actions.close(prompt_bufnr)
        jump_to_selection(selection)
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
