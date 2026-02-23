local M = {}

function M.make_matcher(query, opts)
  opts = opts or {}
  local needle = tostring(query or "")
  if opts.trim then
    needle = vim.trim(needle)
  end
  local ignore_case = opts.ignore_case ~= false
  if ignore_case then
    needle = string.lower(needle)
  end
  if needle == "" then
    return function()
      return true
    end, needle
  end
  local plain = opts.plain ~= false
  return function(haystack)
    local h = tostring(haystack or "")
    if ignore_case then
      h = string.lower(h)
    end
    return string.find(h, needle, 1, plain) ~= nil
  end, needle
end

return M
