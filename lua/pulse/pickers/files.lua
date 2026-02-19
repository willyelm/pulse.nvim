local common = require("pulse.pickers.common")

local M = {}

function M.title()
  return "Files"
end

function M.seed(project_root)
  local opened = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
      local p = vim.api.nvim_buf_get_name(buf)
      if p ~= "" and vim.fn.filereadable(p) == 1 then
        table.insert(opened, p)
      end
    end
  end
  table.sort(opened)

  local recent = {}
  local seen = {}
  for _, p in ipairs(vim.v.oldfiles or {}) do
    if p ~= "" and vim.fn.filereadable(p) == 1 and common.in_project(p, project_root) then
      local abs = common.normalize_path(p)
      if not seen[abs] then
        seen[abs] = true
        table.insert(recent, abs)
      end
    end
  end

  return {
    opened = opened,
    recent = recent,
    files = nil,
    root = project_root,
  }
end

local function ensure_repo_files(state)
  if state.files then
    return state.files
  end
  local files = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
  if vim.v.shell_error ~= 0 then
    state.files = {}
  else
    state.files = files
  end
  return state.files
end

function M.items(state, query)
  local items = {}
  local seen = {}

  if query == "" then
    table.insert(items, { kind = "header", label = "Opened Buffers" })
    for _, p in ipairs(state.opened) do
      if not seen[p] then
        seen[p] = true
        table.insert(items, { kind = "file", path = p })
      end
    end

    table.insert(items, { kind = "header", label = "Recent Files" })
    for _, p in ipairs(state.recent) do
      if not seen[p] then
        seen[p] = true
        table.insert(items, { kind = "file", path = p })
      end
    end
    return items
  end

  for _, p in ipairs(ensure_repo_files(state)) do
    if common.has_ci(p, query) then
      table.insert(items, { kind = "file", path = p })
    end
  end

  return items
end

return M
