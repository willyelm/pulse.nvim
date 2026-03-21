local M = {}

local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
local FILE_ICON_FALLBACK = ""

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function file_icon(path)
  if not ok_devicons then
    return FILE_ICON_FALLBACK
  end
  local icon = devicons.get_icon(vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
  return icon or FILE_ICON_FALLBACK
end

function M.file(path, bufnr)
  path = normalize_path(path)
  if not path then
    return nil
  end
  return {
    kind = "file",
    path = path,
    bufnr = bufnr,
    label = vim.fn.fnamemodify(path, ":t"),
    icon = file_icon(path),
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

return M
