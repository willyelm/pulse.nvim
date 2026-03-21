local M = {}

local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
local FILE_ICON_FALLBACK = ""
local color_hl_cache = {}

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function file_icon(path)
  if not ok_devicons then
    return FILE_ICON_FALLBACK, nil
  end
  local icon, color = devicons.get_icon_color(vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
  return icon or FILE_ICON_FALLBACK, color
end

local function icon_hl(color, fallback)
  if type(color) ~= "string" or color == "" then
    return fallback
  end
  local hl = color_hl_cache[color]
  if hl then
    return hl
  end
  hl = "PulseScopeIcon_" .. color:gsub("[^%w]", "")
  color_hl_cache[color] = hl
  pcall(vim.api.nvim_set_hl, 0, hl, { fg = color })
  return hl
end

function M.file(path, bufnr)
  path = normalize_path(path)
  if not path then
    return nil
  end
  local icon, color = file_icon(path)
  return {
    kind = "file",
    path = path,
    bufnr = bufnr,
    label = vim.fn.fnamemodify(path, ":t"),
    icon = icon,
    icon_hl = icon_hl(color),
  }
end

function M.folder(path)
  path = normalize_path(path)
  if not path then
    return nil
  end
  path = path:gsub("/$", "")
  return {
    kind = "folder",
    path = path,
    label = vim.fn.fnamemodify(path, ":t"),
    icon = "󰉋",
    icon_hl = "Directory",
  }
end

function M.from_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  return M.file(path, bufnr)
end

function M.key(scope)
  if not scope then
    return ""
  end
  return table.concat({
    tostring(scope.kind or ""),
    tostring(scope.path or ""),
    tostring(scope.bufnr or ""),
  }, ":")
end

function M.prompt_text(scope)
  if not scope or not scope.label or scope.label == "" then
    return ""
  end
  return " " .. tostring(scope.icon or "") .. " " .. tostring(scope.label) .. " "
end

function M.prompt_matches(scope, prompt_prefix_len)
  if not scope or not scope.label or scope.label == "" then
    return nil
  end
  local start_col = prompt_prefix_len or 0
  local icon = tostring(scope.icon or "")
  local icon_end = start_col + 1 + #icon
  local label_end = start_col + #M.prompt_text(scope)
  local matches = {
    { start_col, label_end, "PulseNormal" },
  }
  if icon ~= "" and scope.icon_hl then
    matches[#matches + 1] = { start_col + 1, icon_end, scope.icon_hl }
  end
  return matches
end

return M
