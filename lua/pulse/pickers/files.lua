local M = {}

function M.title()
  return "Files"
end

local function has_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
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

local function collect_opened_files()
  local opened = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
      local path = vim.api.nvim_buf_get_name(buf)
      if path ~= "" and vim.fn.filereadable(path) == 1 then
        opened[#opened + 1] = path
      end
    end
  end
  table.sort(opened)
  return opened
end

local function collect_recent_files(project_root)
  local recent, seen = {}, {}
  for _, path in ipairs(vim.v.oldfiles or {}) do
    if path ~= "" and vim.fn.filereadable(path) == 1 and in_project(path, project_root) then
      local abs = normalize_path(path)
      if not seen[abs] then
        seen[abs] = true
        recent[#recent + 1] = abs
      end
    end
  end
  return recent
end

function M.seed(project_root)
  return {
    opened = collect_opened_files(),
    recent = collect_recent_files(project_root),
    files = nil,
  }
end

local function ensure_repo_files(state)
  if state.files then
    return state.files
  end
  local files = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!.git" })
  state.files = (vim.v.shell_error == 0) and files or {}
  return state.files
end

function M.items(state, query)
  local items, seen = {}, {}

  if query == "" then
    items[#items + 1] = { kind = "header", label = "Opened Buffers" }
    for _, path in ipairs(state.opened) do
      if not seen[path] then
        seen[path] = true
        items[#items + 1] = { kind = "file", path = path }
      end
    end

    items[#items + 1] = { kind = "header", label = "Recent Files" }
    for _, path in ipairs(state.recent) do
      if not seen[path] then
        seen[path] = true
        items[#items + 1] = { kind = "file", path = path }
      end
    end

    return items
  end

  for _, path in ipairs(ensure_repo_files(state)) do
    if has_ci(path, query) then
      items[#items + 1] = { kind = "file", path = path }
    end
  end

  return items
end

return M
