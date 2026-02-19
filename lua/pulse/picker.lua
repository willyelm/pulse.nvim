local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")

local M = {}

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

local function has_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

local function parse_mode(prompt)
  if vim.startswith(prompt, ":") then
    return "commands", prompt:sub(2)
  end
  if vim.startswith(prompt, "#") then
    return "workspace_symbol", prompt:sub(2)
  end
  if vim.startswith(prompt, "@") then
    return "symbol", prompt:sub(2)
  end
  return "files", prompt
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function in_project(path, root)
  local p = normalize_path(path)
  local r = normalize_path(root)
  if r:sub(-1) ~= "/" then
    r = r .. "/"
  end
  return p:sub(1, #r) == r
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

local function opened_buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
      local p = vim.api.nvim_buf_get_name(buf)
      if p ~= "" and vim.fn.filereadable(p) == 1 then
        table.insert(out, p)
      end
    end
  end
  table.sort(out)
  return out
end

local function recent_files(root)
  local out = {}
  local seen = {}
  for _, p in ipairs(vim.v.oldfiles or {}) do
    if p ~= "" and vim.fn.filereadable(p) == 1 and in_project(p, root) then
      local abs = normalize_path(p)
      if not seen[abs] then
        seen[abs] = true
        table.insert(out, abs)
      end
    end
  end
  return out
end

local function repo_files()
  local files = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return files
end

local function command_history()
  local out = {}
  local seen = {}
  local last = vim.fn.histnr(":")
  for i = last, math.max(1, last - 250), -1 do
    local c = vim.fn.histget(":", i)
    if c ~= "" and not seen[c] then
      seen[c] = true
      table.insert(out, c)
    end
  end
  return out
end

local function all_commands()
  local out = {}
  local seen = {}
  for _, c in ipairs(vim.fn.getcompletion("", "command")) do
    if c ~= "" and not seen[c] then
      seen[c] = true
      table.insert(out, c)
    end
  end
  table.sort(out)
  return out
end

local function flatten_document_symbols(items, out)
  out = out or {}
  for _, item in ipairs(items or {}) do
    local name = item.name or ""
    local kind = item.kind or 0
    local range = item.selectionRange or item.range
    if range and range.start then
      table.insert(out, {
        kind = "symbol",
        symbol = name,
        symbol_kind = kind,
        lnum = (range.start.line or 0) + 1,
        col = (range.start.character or 0) + 1,
        filename = vim.api.nvim_buf_get_name(0),
      })
    elseif item.location and item.location.range and item.location.range.start then
      table.insert(out, {
        kind = "symbol",
        symbol = name,
        symbol_kind = kind,
        lnum = (item.location.range.start.line or 0) + 1,
        col = (item.location.range.start.character or 0) + 1,
        filename = vim.uri_to_fname(item.location.uri),
      })
    end
    if item.children then
      flatten_document_symbols(item.children, out)
    end
  end
  return out
end

local function document_symbols()
  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  local resp = vim.lsp.buf_request_sync(0, "textDocument/documentSymbol", params, 1000)
  local out = {}
  if not resp then
    return out
  end
  for _, r in pairs(resp) do
    if r.result then
      flatten_document_symbols(r.result, out)
    end
  end
  return out
end

local function workspace_symbols(query)
  local params = { query = query or "" }
  local resp = vim.lsp.buf_request_sync(0, "workspace/symbol", params, 1500)
  local out = {}
  if not resp then
    return out
  end
  for _, r in pairs(resp) do
    for _, item in ipairs(r.result or {}) do
      local filename = item.location and item.location.uri and vim.uri_to_fname(item.location.uri) or ""
      local pos = item.location and item.location.range and item.location.range.start or {}
      table.insert(out, {
        kind = "workspace_symbol",
        symbol = item.name or "",
        symbol_kind = item.kind or 0,
        container = item.containerName or "",
        filename = filename,
        lnum = (pos.line or 0) + 1,
        col = (pos.character or 0) + 1,
      })
    end
  end
  return out
end

local function ensure_repo_files(data)
  if not data.files then
    data.files = repo_files()
  end
  return data.files
end

local function ensure_document_symbols(data)
  if not data.symbols then
    data.symbols = document_symbols()
  end
  return data.symbols
end

local function ensure_workspace_symbols(data)
  if not data.workspace_symbols then
    data.workspace_symbols = workspace_symbols("")
  end
  return data.workspace_symbols
end

local function build_file_items(data, query)
  local items = {}
  local seen = {}

  if query == "" then
    table.insert(items, { kind = "header", label = "Opened Buffers" })
    for _, p in ipairs(data.opened) do
      if not seen[p] then
        seen[p] = true
        table.insert(items, { kind = "file", path = p })
      end
    end

    table.insert(items, { kind = "header", label = "Recent Files" })
    for _, p in ipairs(data.recent) do
      if not seen[p] then
        seen[p] = true
        table.insert(items, { kind = "file", path = p })
      end
    end
    return items
  end

  for _, p in ipairs(ensure_repo_files(data)) do
    if has_ci(p, query) then
      table.insert(items, { kind = "file", path = p })
    end
  end

  return items
end

local function build_command_items(data, query)
  local items = {}
  local seen = {}

  for _, c in ipairs(data.history) do
    if has_ci(c, query) then
      seen[c] = true
      table.insert(items, { kind = "command", command = c, source = "history" })
    end
  end

  for _, c in ipairs(data.commands) do
    if not seen[c] and has_ci(c, query) then
      table.insert(items, { kind = "command", command = c, source = "completion" })
    end
  end

  return items
end

local function filter_symbols(items, query)
  if query == "" then
    return items
  end
  local out = {}
  for _, s in ipairs(items) do
    local hay = table.concat({ s.symbol or "", s.container or "", s.filename or "" }, " ")
    if has_ci(hay, query) then
      table.insert(out, s)
    end
  end
  return out
end

local function build_items(data, prompt)
  local mode, query = parse_mode(prompt or "")
  if mode == "files" then
    return build_file_items(data, query)
  end
  if mode == "commands" then
    return build_command_items(data, query)
  end
  if mode == "symbol" then
    return filter_symbols(ensure_document_symbols(data), query)
  end

  local ws = ensure_workspace_symbols(data)
  if #ws == 0 and query ~= "" then
    ws = workspace_symbols(query)
  end
  return filter_symbols(ws, query)
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

  local data = {
    opened = opened_buffers(),
    recent = recent_files(vim.fn.getcwd()),
    history = command_history(),
    commands = all_commands(),
    files = nil,
    symbols = nil,
    workspace_symbols = nil,
  }

  local picker = pickers.new(opts, {
    prompt_title = "Pulse  (: commands | # workspace | @ symbols)",
    results_title = false,
    finder = finders.new_dynamic({
      fn = function(prompt)
        return build_items(data, prompt)
      end,
      entry_maker = entry_maker,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = false,
    initial_mode = opts.initial_mode,
    prompt_prefix = opts.prompt_prefix,
    selection_caret = opts.selection_caret,
    entry_prefix = opts.entry_prefix,
    layout_strategy = opts.layout_strategy,
    layout_config = opts.layout_config,
    sorting_strategy = opts.sorting_strategy,
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

  if opts.initial_prompt and opts.initial_prompt ~= "" then
    picker:find({ default_text = opts.initial_prompt })
  else
    picker:find()
  end
end

return M
