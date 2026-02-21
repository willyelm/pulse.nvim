local M = {}

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

local ok_devicons, devicons = pcall(require, "nvim-web-devicons")

local function devicon_for(path)
  if not ok_devicons then
    return ""
  end
  local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
  local icon = devicons.get_icon(name, ext, { default = true })
  return icon or ""
end

local function file_kind(path)
  local ft = vim.filetype.match({ filename = path })
  if ft and ft ~= "" then
    return ft
  end
  local ext = vim.fn.fnamemodify(path or "", ":e")
  return (ext ~= "" and ext) or "file"
end

local function row(left, right, left_group)
  return {
    left = left or "",
    left_group = left_group or "Normal",
    right = right or "",
    right_group = "Comment",
  }
end

local function file_name(path)
  return vim.fn.fnamemodify(path or "", ":t")
end

function M.to_display(item)
  if item.kind == "header" then
    return row(item.label or "", "", "Comment")
  end

  if item.kind == "file" then
    local name = file_name(item.path)
    return row(string.format("%s %s", devicon_for(item.path), name), file_kind(item.path))
  end

  if item.kind == "command" then
    return row(string.format("%s :%s", KIND_ICON.Command, item.command))
  end

  if item.kind == "live_grep" then
    local match_line = vim.trim(item.text or "")
    if match_line == "" then
      match_line = file_name(item.path)
    end
    local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
    local out = row(match_line, string.format("%s:%s", file_name(item.path), pos))
    local query = vim.trim(item.query or "")
    if query ~= "" then
      local idx = match_line:lower():find(query:lower(), 1, true)
      if idx then
        out.left_matches = { { idx - 1, idx - 1 + #query } }
      end
    end
    return out
  end

  if item.kind == "fuzzy_search" then
    local match_line = vim.trim(item.text or "")
    if match_line == "" then
      match_line = file_name(item.filename)
    end
    local out = row(match_line, string.format("%d:%d", item.lnum or 1, item.col or 1))
    if type(item.match_cols) == "table" and #item.match_cols > 0 then
      out.left_matches = {}
      for _, col in ipairs(item.match_cols) do
        if type(col) == "number" and col > 0 then
          out.left_matches[#out.left_matches + 1] = { col - 1, col }
        end
      end
    end
    return out
  end

  if item.kind == "git_status" then
    return row(item.display_left or "", item.display_right or "", "Normal")
  end

  if item.kind == "diagnostic" then
    local name = file_name(item.filename)
    local pos = string.format("%s:%d:%d", name, item.lnum or 1, item.col or 1)
    local icon = DIAG_ICON[item.severity_name or "INFO"] or ""
    local msg = (item.message or ""):gsub("\n.*$", "")
    return row(string.format("%s %s", icon, msg), pos)
  end

  local kind = item.symbol_kind_name or "Symbol"
  local icon = KIND_ICON[kind] or KIND_ICON.Symbol
  local depth = math.max(item.depth or 0, 0)
  local indent = string.rep("  ", depth)
  return row(string.format("%s%s %s", indent, icon, item.symbol or ""), kind)
end

return M
