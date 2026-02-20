local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local sorters = require("telescope.sorters")

local modules = {
  files = require("pulse.pickers.files"),
  commands = require("pulse.pickers.commands"),
  symbol = require("pulse.pickers.symbols"),
  workspace_symbol = require("pulse.pickers.workspace_symbols"),
}

local M = {}

local MODE_PREFIX = {
  [":"] = { mode = "commands", strip = 2 },
  ["#"] = { mode = "workspace_symbol", strip = 2 },
  ["@"] = { mode = "symbol", strip = 2 },
}

local KIND_ICON = {
  Command = "", File = "󰈔", Module = "󰆧", Namespace = "󰌗", Package = "󰏗", Class = "󰠱",
  Method = "󰆧", Property = "󰆼", Field = "󰆼", Constructor = "󰆧", Enum = "󰕘", Interface = "󰕘",
  Function = "󰊕", Variable = "󰀫", Constant = "󰏿", String = "󰀬", Number = "󰎠", Boolean = "󰨙",
  Array = "󰅪", Object = "󰅩", Key = "󰌋", Null = "󰟢", EnumMember = "󰕘", Struct = "󰙅",
  Event = "󱐋", Operator = "󰆕", TypeParameter = "󰬛", Symbol = "󰘧",
}

local KIND_HL = {
  File = "Directory", Module = "Include", Namespace = "Include", Package = "Include", Class = "Type",
  Method = "Function", Property = "Identifier", Field = "Identifier", Constructor = "Function", Enum = "Type",
  Interface = "Type", Function = "Function", Variable = "Identifier", Constant = "Constant", String = "String",
  Number = "Number", Boolean = "Boolean", Array = "Type", Object = "Type", Key = "Identifier",
  Null = "Constant", EnumMember = "Constant", Struct = "Type", Event = "PreProc", Operator = "Operator",
  TypeParameter = "Type", Symbol = "Identifier",
}

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
  return (ft and ft ~= "") and ft or "file"
end

local function devicon_for(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", "TelescopeResultsComment"
  end
  local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
  local icon, hl = devicons.get_icon(name, ext, { default = true })
  return icon or "", hl or "TelescopeResultsComment"
end

local function symbol_hl(kind)
  local pulse = "Pulse" .. tostring(kind or "Symbol")
  return (vim.fn.hlexists(pulse) == 1) and pulse or (KIND_HL[kind] or "Identifier")
end

local function parse_prompt(prompt)
  prompt = prompt or ""
  local cfg = MODE_PREFIX[prompt:sub(1, 1)]
  if cfg then
    return cfg.mode, prompt:sub(cfg.strip)
  end
  return "files", prompt
end

local function build_items(states, prompt)
  local mode, query = parse_prompt(prompt)
  return modules[mode].items(states[mode], query), mode
end

local function jump_to(selection)
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

local function make_entry_maker()
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = function(_, cols, _) return math.max(1, cols - 22 - 1) end },
      { width = 22, right_justify = true },
    },
  })

  return function(item)
    if item.kind == "header" then
      return {
        value = item,
        ordinal = item.label,
        kind = "header",
        display = function()
          return displayer({ { item.label, "Comment" }, { "", "Comment" } })
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
          return displayer({ { icon .. " " .. rel, "Normal" }, { filetype_for(item.path), "Comment" } })
        end,
      }
    end

    if item.kind == "command" then
      return {
        value = item,
        ordinal = ":" .. item.command,
        kind = "command",
        display = function()
          return displayer({ { KIND_ICON.Command .. " :" .. item.command, "Normal" }, { item.source, "Comment" } })
        end,
      }
    end

    local kind = item.symbol_kind_name or "Symbol"
    local icon = KIND_ICON[kind] or KIND_ICON.Symbol
    local hl = symbol_hl(kind)
    local indent = string.rep("  ", math.max(item.depth or 0, 0))
    local filename = item.filename or ""
    local rel = filename ~= "" and vim.fn.fnamemodify(filename, ":.") or ""
    local right = (item.kind == "workspace_symbol" and item.container and item.container ~= "") and (kind .. "  " .. item.container) or kind

    return {
      value = item,
      ordinal = ((item.kind == "workspace_symbol") and "#" or "@") .. " " .. string.format("%s %s %s", item.symbol or "", rel, item.container or ""),
      filename = filename,
      lnum = item.lnum,
      col = item.col,
      kind = item.kind,
      display = function()
        return displayer({ { indent .. icon .. " " .. (item.symbol or ""), hl }, { right, "Comment" } })
      end,
    }
  end
end

local function set_results_winhl(prompt_bufnr)
  vim.schedule(function()
    local p = action_state.get_current_picker(prompt_bufnr)
    if p and p.results_win and vim.api.nvim_win_is_valid(p.results_win) then
      vim.api.nvim_set_option_value("winhl", "Normal:Normal,CursorLine:CursorLine", { win = p.results_win })
    end
  end)
end

local function ensure_first_selectable(prompt_bufnr)
  vim.schedule(function()
    local sel = action_state.get_selected_entry()
    if sel and sel.kind == "header" then
      actions.move_selection_next(prompt_bufnr)
      local sel2 = action_state.get_selected_entry()
      local guard = 0
      while sel2 and sel2.kind == "header" and guard < 200 do
        actions.move_selection_next(prompt_bufnr)
        sel2 = action_state.get_selected_entry()
        guard = guard + 1
      end
    end
  end)
end

local function skip_headers(prompt_bufnr, move)
  local i = 0
  repeat
    move(prompt_bufnr)
    i = i + 1
    local s = action_state.get_selected_entry()
    if not s or s.kind ~= "header" then
      return
    end
  until i > 200
end

function M.open(opts)
  local picker_opts = vim.tbl_deep_extend("force", {
    layout_config = { width = 0.70, height = 0.45, prompt_position = "top", anchor = "N" },
    border = true,
  }, opts or {})

  local ok, themes = pcall(require, "telescope.themes")
  if ok and type(themes.get_dropdown) == "function" then
    picker_opts = themes.get_dropdown(picker_opts)
  end

  picker_opts.layout_config = vim.tbl_deep_extend("force", picker_opts.layout_config or {}, {
    anchor = "N",
    prompt_position = "top",
  })

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

  picker = pickers.new(picker_opts, {
    prompt_title = modules.files.title(),
    results_title = false,
    finder = finders.new_dynamic({
      fn = function(prompt)
        local items, mode = build_items(states, prompt)
        local title = modules[mode].title()
        if picker and picker.prompt_title ~= title then
          picker.prompt_title = title
          if picker.prompt_border and picker.prompt_border.change_title then
            pcall(picker.prompt_border.change_title, picker.prompt_border, title)
          end
        end
        return items
      end,
      entry_maker = make_entry_maker(),
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
      ensure_first_selectable(prompt_bufnr)

      local function move_next()
        skip_headers(prompt_bufnr, actions.move_selection_next)
      end
      local function move_prev()
        skip_headers(prompt_bufnr, actions.move_selection_previous)
      end

      local function preview_selection()
        local s = action_state.get_selected_entry()
        if not s then
          return
        end
        if s.kind == "header" then
          move_next()
          return
        end
        if s.kind == "symbol" or s.kind == "workspace_symbol" or s.kind == "file" then
          local p = action_state.get_current_picker(prompt_bufnr)
          local target_win = p and p.original_win_id or nil
          if target_win and vim.api.nvim_win_is_valid(target_win) then
            vim.api.nvim_win_call(target_win, function()
              jump_to(s)
            end)
          end
        end
      end

      local next_keys = { { "i", "<Down>" }, { "i", "<C-n>" }, { "n", "j" }, { "n", "<Down>" } }
      local prev_keys = { { "i", "<Up>" }, { "i", "<C-p>" }, { "n", "k" }, { "n", "<Up>" } }
      for _, k in ipairs(next_keys) do map(k[1], k[2], move_next) end
      for _, k in ipairs(prev_keys) do map(k[1], k[2], move_prev) end
      map("i", "<Tab>", preview_selection)
      map("n", "<Tab>", preview_selection)

      actions.select_default:replace(function()
        local s = action_state.get_selected_entry()
        if not s or s.kind == "header" then
          return
        end
        actions.close(prompt_bufnr)
        jump_to(s)
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
