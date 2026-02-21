local M = {}

local DIFF_ADD_HL = (vim.fn.hlexists("PulseDiffAdd") == 1)
    and "PulseDiffAdd"
  or ((vim.fn.hlexists("DiffAdded") == 1) and "DiffAdded" or "DiffAdd")
local DIFF_DEL_HL = (vim.fn.hlexists("PulseDiffDelete") == 1) and "PulseDiffDelete" or "DiffDelete"
local DIFF_NUM_ADD_HL = (vim.fn.hlexists("PulseDiffNAdd") == 1) and "PulseDiffNAdd" or DIFF_ADD_HL
local DIFF_NUM_DEL_HL = (vim.fn.hlexists("PulseDiffNDelete") == 1) and "PulseDiffNDelete" or DIFF_DEL_HL

local function ensure_lines(lines)
  if type(lines) ~= "table" then
    return {}
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = tostring(line or "")
  end
  return out
end

local function diff_indices(old_lines, new_lines, algorithm)
  local a = table.concat(old_lines, "\n")
  local b = table.concat(new_lines, "\n")
  local ok, hunks = pcall(vim.diff, a, b, { result_type = "indices", algorithm = algorithm or "myers" })
  return (ok and type(hunks) == "table") and hunks or {}
end

local function push(rows, old_ln, new_ln, sign, text)
  rows[#rows + 1] = {
    old_ln = old_ln,
    new_ln = new_ln,
    sign = sign,
    text = text or "",
    changed = (sign == "+" or sign == "-"),
  }
end

local function to_rows(old_lines, new_lines, hunks, old_start, new_start)
  local rows = {}
  local oi, ni = 1, 1

  local function emit_equal(to_oi, to_ni)
    while oi < to_oi and ni < to_ni do
      push(rows, old_start + oi - 1, new_start + ni - 1, " ", new_lines[ni] or "")
      oi = oi + 1
      ni = ni + 1
    end
  end

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    emit_equal(sa, sb)
    for i = sa, sa + ca - 1 do
      push(rows, old_start + i - 1, nil, "-", old_lines[i] or "")
    end
    for i = sb, sb + cb - 1 do
      push(rows, nil, new_start + i - 1, "+", new_lines[i] or "")
    end
    oi = sa + ca
    ni = sb + cb
  end

  emit_equal(#old_lines + 1, #new_lines + 1)
  return rows
end

local function trim_rows(rows, context)
  if not context or context < 0 then
    return rows
  end
  local keep = {}
  local changed = false
  for i, r in ipairs(rows) do
    if r.changed then
      changed = true
      local from = math.max(1, i - context)
      local to = math.min(#rows, i + context)
      for j = from, to do
        keep[j] = true
      end
    end
  end
  if not changed then
    return rows
  end
  local out = {}
  for i, r in ipairs(rows) do
    if keep[i] then
      out[#out + 1] = r
    end
  end
  return out
end

local function number_width(rows)
  local mo, mn = 1, 1
  for _, r in ipairs(rows) do
    if r.old_ln then mo = math.max(mo, r.old_ln) end
    if r.new_ln then mn = math.max(mn, r.new_ln) end
  end
  return math.max(#tostring(mo), 2), math.max(#tostring(mn), 2)
end

local function render(rows)
  local w_old, w_new = number_width(rows)
  local lines, highlights = {}, {}
  local focus_row = 1
  local focused = false

  for i, r in ipairs(rows) do
    local old_txt = r.old_ln and tostring(r.old_ln) or ""
    local new_txt = r.new_ln and tostring(r.new_ln) or ""
    lines[i] = string.format("%" .. w_old .. "s %" .. w_new .. "s %s %s", old_txt, new_txt, r.sign, r.text)
    local row = i - 1
    local old_from = 0
    local old_to = w_old
    local new_from = w_old + 1
    local new_to = w_old + 1 + w_new
    local sign_from = w_old + w_new + 2
    local sign_to = sign_from + 1
    if r.sign == "+" then
      highlights[#highlights + 1] = { group = DIFF_ADD_HL, row = row, start_col = 0, end_col = -1 }
      highlights[#highlights + 1] = { group = DIFF_NUM_ADD_HL, row = row, start_col = old_from, end_col = old_to }
      highlights[#highlights + 1] = { group = DIFF_NUM_ADD_HL, row = row, start_col = new_from, end_col = new_to }
      highlights[#highlights + 1] = { group = DIFF_NUM_ADD_HL, row = row, start_col = sign_from, end_col = sign_to }
      if not focused then focus_row, focused = i, true end
    elseif r.sign == "-" then
      highlights[#highlights + 1] = { group = DIFF_DEL_HL, row = row, start_col = 0, end_col = -1 }
      highlights[#highlights + 1] = { group = DIFF_NUM_DEL_HL, row = row, start_col = old_from, end_col = old_to }
      highlights[#highlights + 1] = { group = DIFF_NUM_DEL_HL, row = row, start_col = new_from, end_col = new_to }
      highlights[#highlights + 1] = { group = DIFF_NUM_DEL_HL, row = row, start_col = sign_from, end_col = sign_to }
      if not focused then focus_row, focused = i, true end
    end
  end

  if #lines == 0 then
    lines[1] = "No changes"
  end
  return lines, highlights, focus_row
end

function M.from_lines(old_lines, new_lines, opts)
  opts = opts or {}
  local old_l = ensure_lines(old_lines)
  local new_l = ensure_lines(new_lines)
  local hunks = diff_indices(old_l, new_l, opts.algorithm)
  local rows = to_rows(old_l, new_l, hunks, opts.old_start or 1, opts.new_start or 1)
  rows = trim_rows(rows, (opts.context == nil) and 3 or opts.context)
  return render(rows)
end

return M
