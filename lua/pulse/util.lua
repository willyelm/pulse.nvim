local M = {}

function M.contains_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), needle, 1, true) ~= nil
end

return M
