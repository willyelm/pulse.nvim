local M = {}

function M.has_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

function M.parse_mode(prompt)
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

function M.normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

function M.in_project(path, root)
  local p = M.normalize_path(path)
  local r = M.normalize_path(root)
  if r:sub(-1) ~= "/" then
    r = r .. "/"
  end
  return p:sub(1, #r) == r
end

return M
