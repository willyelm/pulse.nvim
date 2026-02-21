local M = {}

local function hl(name, fallback)
  return (vim.fn.hlexists(name) == 1) and name or fallback
end

local DIFF_ADD_HL = hl("PulseDiffAdd", hl("DiffAdded", "DiffAdd"))
local DIFF_DEL_HL = hl("PulseDiffDelete", "DiffDelete")
local NUM_ADD_HL = hl("PulseDiffNAdd", DIFF_ADD_HL)
local NUM_DEL_HL = hl("PulseDiffNDelete", DIFF_DEL_HL)

local function norm(lines)
  if type(lines) ~= "table" then
    return {}
  end
  for i, v in ipairs(lines) do
    lines[i] = tostring(v or "")
  end
  return lines
end

local function rows_from_hunks(old_l, new_l, hunks, old_start, new_start)
  local rows, oi, ni = {}, 1, 1
  local function add(old_ln, new_ln, sign, text)
    rows[#rows + 1] = { old = old_ln, new = new_ln, sign = sign, text = text, changed = sign ~= " " }
  end
  local function equal_until(to_oi, to_ni)
    while oi < to_oi and ni < to_ni do
      add(old_start + oi - 1, new_start + ni - 1, " ", new_l[ni] or "")
      oi, ni = oi + 1, ni + 1
    end
  end
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    equal_until(sa, sb)
    for i = sa, sa + ca - 1 do add(old_start + i - 1, nil, "-", old_l[i] or "") end
    for i = sb, sb + cb - 1 do add(nil, new_start + i - 1, "+", new_l[i] or "") end
    oi, ni = sa + ca, sb + cb
  end
  equal_until(#old_l + 1, #new_l + 1)
  return rows
end

local function trim(rows, context)
  if context == nil then context = 3 end
  if context < 0 then return rows end
  local keep, changed = {}, false
  for i, r in ipairs(rows) do
    if r.changed then
      changed = true
      for j = math.max(1, i - context), math.min(#rows, i + context) do keep[j] = true end
    end
  end
  if not changed then return rows end
  local out = {}
  for i, r in ipairs(rows) do if keep[i] then out[#out + 1] = r end end
  return out
end

function M.from_lines(old_lines, new_lines, opts)
  opts = opts or {}
  local old_l = norm(vim.deepcopy(old_lines))
  local new_l = norm(vim.deepcopy(new_lines))
  local ok, hunks = pcall(vim.diff, table.concat(old_l, "\n"), table.concat(new_l, "\n"), {
    result_type = "indices",
    algorithm = opts.algorithm or "myers",
  })
  hunks = (ok and type(hunks) == "table") and hunks or {}
  local rows = trim(rows_from_hunks(old_l, new_l, hunks, opts.old_start or 1, opts.new_start or 1), opts.context)

  local mo, mn = 1, 1
  for _, r in ipairs(rows) do
    if r.old then mo = math.max(mo, r.old) end
    if r.new then mn = math.max(mn, r.new) end
  end
  local w_old, w_new = math.max(#tostring(mo), 2), math.max(#tostring(mn), 2)
  local lines, highlights, focus = {}, {}, 1

  for i, r in ipairs(rows) do
    lines[i] = string.format(" %" .. w_old .. "s %" .. w_new .. "s  %s %s", r.old or "", r.new or "", r.sign, r.text or "")
    local row = i - 1
    local num_group = (r.sign == "+") and NUM_ADD_HL or ((r.sign == "-") and NUM_DEL_HL or nil)
    local line_group = (r.sign == "+") and DIFF_ADD_HL or ((r.sign == "-") and DIFF_DEL_HL or nil)
    if line_group then
      highlights[#highlights + 1] = { group = line_group, row = row, start_col = 0, end_col = -1 }
      if focus == 1 then focus = i end
    end
    if num_group then
      local sign_col = w_old + w_new + 3
      highlights[#highlights + 1] = { group = num_group, row = row, start_col = 0, end_col = sign_col }
    end
  end

  if #lines == 0 then
    return { "No changes" }, {}, 1
  end
  return lines, highlights, focus
end

return M
