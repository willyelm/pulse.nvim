local M = {}

local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
local FILE_ICON_FALLBACK = ""
local MAX_LABEL_LEN = 24

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
  local icon, hl = devicons.get_icon(vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e"), { default = true })
  return icon or FILE_ICON_FALLBACK, hl
end

function M.file(path, bufnr)
  path = normalize_path(path)
  if not path then
    return nil
  end
  local icon, hl = file_icon(path)
  return {
    kind = "file",
    path = path,
    bufnr = bufnr,
    label = vim.fn.fnamemodify(path, ":t"),
    icon = icon,
    icon_hl = hl,
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
  if not M.valid_bufnr(bufnr) then
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

local function display_label(scope)
  local label = tostring(scope and scope.label or "")
  if label == "" or #label <= MAX_LABEL_LEN then
    return label
  end
  return label:sub(1, MAX_LABEL_LEN - 3) .. "..."
end

function M.prompt_text(scope)
  local label = display_label(scope)
  if not scope or label == "" then
    return ""
  end
  return " " .. tostring(scope.icon or "") .. " " .. label .. " "
end

function M.prompt_matches(scope, prompt_prefix_len)
  local label = display_label(scope)
  if not scope or label == "" then
    return nil
  end
  local start_col = prompt_prefix_len or 0
  local text = M.prompt_text(scope)
  local matches = {
    { start_col, start_col + #text, "PulseNormal" },
  }
  if scope.kind == "file" and scope.icon_hl then
    matches[#matches + 1] = { start_col + 1, start_col + 1 + #(scope.icon or ""), scope.icon_hl }
  end
  return matches
end

function M.valid_bufnr(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

function M.resolve_bufnr(ctx)
  local scoped = ctx and ctx.scope or nil
  local bufnr = nil

  if scoped and scoped.kind == "file" then
    bufnr = scoped.bufnr
    if not M.valid_bufnr(bufnr) and scoped.path and scoped.path ~= "" then
      local existing = vim.fn.bufnr(scoped.path)
      if type(existing) == "number" and existing > 0 then
        bufnr = existing
      else
        bufnr = vim.fn.bufadd(scoped.path)
      end
    end
  end

  if not M.valid_bufnr(bufnr) then
    bufnr = ctx and ctx.bufnr or nil
  end
  if not M.valid_bufnr(bufnr) then
    bufnr = vim.api.nvim_get_current_buf()
  end

  return M.valid_bufnr(bufnr) and bufnr or nil
end

function M.input_scope(ctx, bufnr)
  local scoped = ctx and ctx.scope or nil
  if scoped and scoped.kind == "file" and scoped.path and bufnr then
    return M.file(scoped.path, bufnr)
  end
  if bufnr then
    return M.from_buffer(bufnr)
  end
  return nil
end

return M
