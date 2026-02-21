local ui = require("pulse.ui")

local modules = {
  files = require("pulse.pickers.files"),
  commands = require("pulse.pickers.commands"),
  symbol = require("pulse.pickers.symbols"),
  workspace_symbol = require("pulse.pickers.workspace_symbols"),
  live_grep = require("pulse.pickers.live_grep"),
  git_status = require("pulse.pickers.git_status"),
  diagnostics = require("pulse.pickers.diagnostics"),
}

local M = {}

local MODE_PREFIX = {
  [":"] = { mode = "commands", strip = 2 },
  ["#"] = { mode = "workspace_symbol", strip = 2 },
  ["@"] = { mode = "symbol", strip = 2 },
  ["$"] = { mode = "live_grep", strip = 2 },
  ["~"] = { mode = "git_status", strip = 2 },
  ["!"] = { mode = "diagnostics", strip = 2 },
}

local KIND_ICON = {
  Command = "",
  File = "󰈔",
  Module = "󰆧",
  Namespace = "󰌗",
  Package = "󰏗",
  Class = "󰠱",
  Method = "󰆧",
  Property = "󰆼",
  Field = "󰆼",
  Constructor = "󰆧",
  Enum = "󰕘",
  Interface = "󰕘",
  Function = "󰊕",
  Variable = "󰀫",
  Constant = "󰏿",
  String = "󰀬",
  Number = "󰎠",
  Boolean = "󰨙",
  Array = "󰅪",
  Object = "󰅩",
  Key = "󰌋",
  Null = "󰟢",
  EnumMember = "󰕘",
  Struct = "󰙅",
  Event = "󱐋",
  Operator = "󰆕",
  TypeParameter = "󰬛",
  Symbol = "󰘧",
}

local DIAG_ICON = {
  ERROR = "",
  WARN = "",
  INFO = "",
  HINT = "󰌵",
}

local function filetype_for(path)
  local ft = vim.filetype.match({ filename = path })
  ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
  return (ft and ft ~= "") and ft or "file"
end

local function devicon_for(path)
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return ""
  end
  local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
  local icon = devicons.get_icon(name, ext, { default = true })
  return icon or ""
end

local function parse_prompt(prompt)
  prompt = prompt or ""
  local cfg = MODE_PREFIX[prompt:sub(1, 1)]
  if cfg then
    return cfg.mode, prompt:sub(cfg.strip)
  end
  return "files", prompt
end

local function jump_to(selection)
  if selection.kind == "file" then
    vim.cmd.edit(vim.fn.fnameescape(selection.path))
    return
  end
  if selection.kind == "command" then
    local keys = vim.api.nvim_replace_termcodes(":" .. selection.command, true, false, true)
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

local function execute_command(cmd)
  local ex = vim.trim(cmd or "")
  if ex == "" then
    return
  end
  local ok, err = pcall(vim.cmd, ex)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

local function resolve_path(path)
  if not path or path == "" then
    return nil
  end
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(abs) == 1 then
    return abs
  end
  return nil
end

local function to_display(item)
  if item.kind == "header" then
    return item.label, "Comment"
  end

  if item.kind == "file" then
    local rel = vim.fn.fnamemodify(item.path, ":.")
    return string.format("%s %s", devicon_for(item.path), rel), "Normal"
  end

  if item.kind == "command" then
    return string.format("%s :%s", KIND_ICON.Command, item.command), "Normal"
  end

  if item.kind == "live_grep" then
    local rel = vim.fn.fnamemodify(item.path, ":.")
    local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
    return string.format("󰱼 %s %s  %s", rel, pos, item.text or ""), "Normal"
  end

  if item.kind == "git_status" then
    local rel = vim.fn.fnamemodify(item.path, ":.")
    return string.format("󰊢 %s  [%s]", rel, item.code or ""), "Normal"
  end

  if item.kind == "diagnostic" then
    local rel = vim.fn.fnamemodify(item.filename or "", ":.")
    local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
    local icon = DIAG_ICON[item.severity_name or "INFO"] or ""
    local msg = (item.message or ""):gsub("\n.*$", "")
    return string.format("%s %s %s  [%s %s]", icon, rel, msg, item.severity_name or "INFO", pos), "Normal"
  end

  local kind = item.symbol_kind_name or "Symbol"
  local icon = KIND_ICON[kind] or KIND_ICON.Symbol
  local depth = math.max(item.depth or 0, 0)
  local indent = string.rep("  ", depth)
  local container = item.container and item.container ~= "" and ("  [" .. item.container .. "]") or ""
  return string.format("%s%s %s%s", indent, icon, item.symbol or "", container), "Normal"
end

local function preview_file_snippet(path, lnum, query)
  local resolved = resolve_path(path)
  if not resolved then
    return { "File not found: " .. tostring(path) }, "text", {}, nil, 1
  end

  local lines = vim.fn.readfile(resolved)
  local line_no = math.max(lnum or 1, 1)
  local start_l = math.max(line_no - 1, 1)
  local end_l = math.min(#lines, line_no + 9)
  local out = {}
  local highlights = {}
  local line_numbers = {}

  for i = start_l, end_l do
    out[#out + 1] = lines[i] or ""
    line_numbers[#line_numbers + 1] = i
  end

  if query and query ~= "" then
    local text = lines[line_no] or ""
    local from = text:lower():find(query:lower(), 1, true)
    if from then
      highlights[#highlights + 1] = {
        group = "Search",
        row = line_no - start_l,
        start_col = from - 1,
        end_col = from - 1 + #query,
      }
    end
  end

  return out, filetype_for(resolved), highlights, line_numbers, (line_no - start_l + 1)
end

local function preview_for_item(item)
  if not item then
    return { "No selection" }, "text", {}, nil, 1
  end

  if item.kind == "header" then
    return { item.label or "" }, "text", {}, nil, 1
  end

  if item.kind == "git_status" then
    local path = item.path or item.filename
    local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
    if vim.v.shell_error ~= 0 or #diff == 0 then
      diff = { "No git diff for " .. tostring(path) }
    end
    return diff, "diff", {}, nil, 1
  end

  if item.kind == "live_grep" then
    return preview_file_snippet(item.path or item.filename, item.lnum, item.query)
  end

  if item.kind == "diagnostic" then
    local out = {
      string.format("[%s] %s", item.severity_name or "INFO", item.source or "diagnostic"),
      string.format("%s:%d:%d", item.filename or "", item.lnum or 1, item.col or 1),
      "",
      item.message or "",
      "",
    }
    local snippet, ft = preview_file_snippet(item.filename, item.lnum)
    vim.list_extend(out, snippet)
    return out, ft, {}, nil, 1
  end

  if item.kind == "file" or item.kind == "symbol" or item.kind == "workspace_symbol" then
    return preview_file_snippet(item.path or item.filename, item.lnum)
  end

  if item.kind == "command" then
    return {
      "Command",
      "",
      ":" .. tostring(item.command),
      "",
      "Press <CR> to execute selected command.",
      "Typing after ':' and pressing <CR> executes typed command.",
    }, "text", {}, nil, 1
  end

  return { vim.inspect(item) }, "lua", {}, nil, 1
end

local function normalise_border(border)
  if border == true or border == nil then
    return "rounded"
  end
  if border == false then
    return "none"
  end
  return border
end

local function list_has_only_headers(items)
  if #items == 0 then
    return false
  end
  for _, item in ipairs(items) do
    if item.kind ~= "header" then
      return false
    end
  end
  return true
end

function M.open(opts)
  local picker_opts = vim.tbl_deep_extend("force", {
    initial_mode = "insert",
    prompt_prefix = "",
    layout_config = {
      width = 0.70,
      height = 0.70,
      prompt_position = "top",
      anchor = "N",
    },
    border = true,
  }, opts or {})

  local source_bufnr = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local states = {}

  local palette = {
    current_mode = "files",
    items = {},
    closed = false,
  }

  local box = ui.box.new({
    width = picker_opts.layout_config.width or 0.70,
    height = picker_opts.layout_config.height or 0.50,
    row = (picker_opts.layout_config.anchor == "N") and 0.12 or nil,
    col = 0.5,
    border = normalise_border(picker_opts.border),
    title = modules.files.title(),
    focusable = true,
    zindex = 60,
    winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
  })

  box:mount()
  local lifecycle_group = vim.api.nvim_create_augroup("PulseUIPalette" .. tostring(box.buf), { clear = true })

  local function close_palette()
    if palette.closed then
      return
    end
    palette.closed = true
    box:unmount()
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = lifecycle_group,
    pattern = tostring(box.win),
    once = true,
    callback = close_palette,
  })

  local function refresh_no_prompt_reset()
    if palette.closed then
      return
    end
    vim.schedule(function()
      if palette.closed then
        return
      end
      palette.refresh()
    end)
  end

  local function ensure_state(mode)
    if states[mode] then
      return states[mode]
    end

    if mode == "files" then
      states[mode] = modules.files.seed(vim.fn.getcwd())
    elseif mode == "commands" then
      states[mode] = modules.commands.seed()
    else
      states[mode] = modules[mode].seed({ on_update = refresh_no_prompt_reset, bufnr = source_bufnr })
    end

    return states[mode]
  end

  local input_section = box:create_section("input", {
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(box.win),
    height = 1,
    focusable = true,
    enter = false,
    winhl = "Normal:NormalFloat",
  })

  local divider_section = box:create_section("divider", {
    row = 1,
    col = 0,
    width = vim.api.nvim_win_get_width(box.win),
    height = 1,
    focusable = false,
    enter = false,
    winhl = "Normal:FloatBorder",
  })

  local list_section = box:create_section("list", {
    row = 2,
    col = 0,
    width = vim.api.nvim_win_get_width(box.win),
    height = 10,
    focusable = true,
    enter = false,
    winhl = "Normal:NormalFloat,CursorLine:CursorLine",
  })

  local body_divider_section = box:create_section("body_divider", {
    row = 12,
    col = 0,
    width = vim.api.nvim_win_get_width(box.win),
    height = 1,
    focusable = false,
    enter = false,
    winhl = "Normal:FloatBorder",
  })

  local preview_section = box:create_section("preview", {
    row = 13,
    col = 0,
    width = vim.api.nvim_win_get_width(box.win),
    height = 8,
    focusable = true,
    enter = false,
    winhl = "Normal:NormalFloat",
  })

  local list = ui.list.new({
    buf = list_section.buf,
    win = list_section.win,
    max_visible = 15,
    min_visible = 3,
    render_item = to_display,
  })

  local preview = ui.preview.new({
    buf = preview_section.buf,
    win = preview_section.win,
  })

  local function resize_layout()
    if palette.closed then
      return
    end

    local total_width = vim.api.nvim_win_get_width(box.win)
    local body_height = list.visible_count
    local preview_height = math.max(math.min(math.floor((vim.o.lines - vim.o.cmdheight) * 0.22), 12), 6)

    box:update({
      height = body_height + preview_height + 3,
    })

    local updated_width = vim.api.nvim_win_get_width(box.win)

    box:create_section("input", {
      row = 0,
      col = 0,
      width = updated_width,
      height = 1,
      focusable = true,
      enter = false,
      buf = input_section.buf,
      winhl = "Normal:NormalFloat",
    })

    local divider_text = string.rep("─", updated_width)
    vim.bo[divider_section.buf].modifiable = true
    vim.api.nvim_buf_set_lines(divider_section.buf, 0, -1, false, { divider_text })
    vim.bo[divider_section.buf].modifiable = false

    box:create_section("divider", {
      row = 1,
      col = 0,
      width = updated_width,
      height = 1,
      focusable = false,
      enter = false,
      buf = divider_section.buf,
      winhl = "Normal:FloatBorder",
    })

    box:create_section("list", {
      row = 2,
      col = 0,
      width = updated_width,
      height = body_height,
      focusable = true,
      enter = false,
      buf = list_section.buf,
      winhl = "Normal:NormalFloat,CursorLine:CursorLine",
    })

    vim.bo[body_divider_section.buf].modifiable = true
    vim.api.nvim_buf_set_lines(body_divider_section.buf, 0, -1, false, { divider_text })
    vim.bo[body_divider_section.buf].modifiable = false
    box:create_section("body_divider", {
      row = 2 + body_height,
      col = 0,
      width = updated_width,
      height = 1,
      focusable = false,
      enter = false,
      buf = body_divider_section.buf,
      winhl = "Normal:FloatBorder",
    })

    box:create_section("preview", {
      row = 3 + body_height,
      col = 0,
      width = updated_width,
      height = preview_height,
      focusable = true,
      enter = false,
      buf = preview_section.buf,
      winhl = "Normal:NormalFloat",
    })

    list.win = box:section("list").win
    preview.win = box:section("preview").win
    input_section.win = box:section("input").win
    if palette.input then
      palette.input.win = input_section.win
    end
  end

  local function selected_or_first_selectable()
    local selected = list:selected_item()
    if selected and selected.kind ~= "header" then
      return selected
    end

    for _, item in ipairs(palette.items) do
      if item.kind ~= "header" then
        return item
      end
    end

    return nil
  end

  local function refresh_preview()
    local item = selected_or_first_selectable()
    local lines, ft, highlights, line_numbers, focus_row = preview_for_item(item)
    preview:set(lines, ft, highlights, line_numbers, focus_row)
  end

  function palette.refresh()
    local prompt = palette.input:get_value()
    local mode, query = parse_prompt(prompt)
    palette.current_mode = mode
    local title = modules[mode].title()
    box:set_title(title)

    local items = modules[mode].items(ensure_state(mode), query)
    if list_has_only_headers(items) then
      items = {}
    end

    palette.items = items
    list:set_items(items)

    local selected = list:selected_item()
    if selected and selected.kind == "header" then
      list:move(1, function(item)
        return item.kind == "header"
      end)
    end

    resize_layout()
    list:render(vim.api.nvim_win_get_width(list.win))
    refresh_preview()
  end

  local function preview_selection_in_source()
    local item = list:selected_item()
    if not item or item.kind == "header" then
      return
    end
    if item.kind == "symbol" or item.kind == "workspace_symbol" or item.kind == "file" or item.kind == "live_grep" then
      if vim.api.nvim_win_is_valid(source_win) then
        vim.api.nvim_win_call(source_win, function()
          jump_to(item)
        end)
      end
    end
  end

  local function move_next()
    list:move(1, function(item)
      return item.kind == "header"
    end)
    list:render(vim.api.nvim_win_get_width(list.win))
    refresh_preview()
  end

  local function move_prev()
    list:move(-1, function(item)
      return item.kind == "header"
    end)
    list:render(vim.api.nvim_win_get_width(list.win))
    refresh_preview()
  end

  vim.keymap.set("n", "<ScrollWheelDown>", function()
    move_next()
  end, { buffer = list.buf, noremap = true, silent = true })

  vim.keymap.set("n", "<ScrollWheelUp>", function()
    move_prev()
  end, { buffer = list.buf, noremap = true, silent = true })

  local function submit(prompt)
    local mode, query = parse_prompt(prompt)
    local selected = list:selected_item()

    if mode == "commands" then
      close_palette()
      if query ~= "" then
        execute_command(query)
        return
      end
      if selected and selected.kind == "command" then
        execute_command(selected.command)
      end
      return
    end

    if not selected or selected.kind == "header" then
      return
    end

    close_palette()
    if vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_win_call(source_win, function()
        jump_to(selected)
      end)
    end
  end

  palette.input = ui.input.new({
    buf = input_section.buf,
    win = input_section.win,
    prompt = picker_opts.prompt_prefix or "",
    on_change = function()
      palette.refresh()
    end,
    on_submit = submit,
    on_escape = close_palette,
    on_down = move_next,
    on_up = move_prev,
    on_tab = preview_selection_in_source,
  })

  local list_map_opts = { buffer = list_section.buf, noremap = true, silent = true }
  vim.keymap.set("n", "j", move_next, list_map_opts)
  vim.keymap.set("n", "k", move_prev, list_map_opts)
  vim.keymap.set("n", "<CR>", function()
    submit(palette.input:get_value())
  end, list_map_opts)
  vim.keymap.set("n", "<Esc>", close_palette, list_map_opts)

  vim.api.nvim_create_autocmd("VimResized", {
    group = lifecycle_group,
    callback = function()
      if palette.closed then
        return
      end
      resize_layout()
      list:render(vim.api.nvim_win_get_width(list.win))
      refresh_preview()
    end,
  })

  if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
    palette.input:set_value(picker_opts.initial_prompt)
  end

  palette.refresh()
  palette.input:focus(picker_opts.initial_mode ~= "normal")
end

return M
