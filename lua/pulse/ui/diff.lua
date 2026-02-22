local M = {}
local function hl(name, fallback)
  return (vim.fn.hlexists(name) == 1) and name or fallback
end
local CONTENT_ADD_HL = hl("DiffAdd", hl("PulseDiffAdd", hl("DiffAdded", "DiffAdd")))
local CONTENT_DEL_HL = hl("DiffDelete", hl("PulseDiffDelete", "DiffDelete"))
local NUM_ADD_HL = hl("PulseDiffNAdd", CONTENT_ADD_HL)
local NUM_DEL_HL = hl("PulseDiffNDelete", CONTENT_DEL_HL)
local SIGN_ADD_HL = CONTENT_ADD_HL
local SIGN_DEL_HL = CONTENT_DEL_HL
local PRIO_CONTENT = 20
local PRIO_NUM = 200
local PRIO_SIGN = 210
local CONTENT_PAD = 160
local STYLE_BY_SIGN = {
  ["+"] = { content = CONTENT_ADD_HL, num = NUM_ADD_HL, sign = SIGN_ADD_HL },
  ["-"] = { content = CONTENT_DEL_HL, num = NUM_DEL_HL, sign = SIGN_DEL_HL },
}
local function norm(lines)
  local out = {}
  for i, v in ipairs(type(lines) == "table" and lines or {}) do
    out[i] = tostring(v or "")
  end
  return out
end
local function rows_from_hunks(old_l, new_l, hunks, old_start, new_start)
  local rows, oi, ni = {}, 1, 1
  local function push(old_ln, new_ln, sign, text)
    rows[#rows + 1] = { old = old_ln, new = new_ln, sign = sign, text = text }
  end
  local function flush_equal(to_oi, to_ni)
    while oi < to_oi and ni < to_ni do
      push(old_start + oi - 1, new_start + ni - 1, " ", new_l[ni] or "")
      oi, ni = oi + 1, ni + 1
    end
  end
  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    flush_equal(sa, sb)
    for i = sa, sa + ca - 1 do push(old_start + i - 1, nil, "-", old_l[i] or "") end
    for i = sb, sb + cb - 1 do push(nil, new_start + i - 1, "+", new_l[i] or "") end
    oi, ni = sa + ca, sb + cb
  end
  flush_equal(#old_l + 1, #new_l + 1)
  return rows
end
local function trim(rows, context)
  context = (context == nil) and 3 or context
  if context < 0 then return rows end
  local keep, changed = {}, false
  for i, r in ipairs(rows) do
    if r.sign ~= " " then
      changed = true
      for j = math.max(1, i - context), math.min(#rows, i + context) do keep[j] = true end
    end
  end
  if not changed then return rows end
  local out = {}
  for i, r in ipairs(rows) do if keep[i] then out[#out + 1] = r end end
  return out
end
local function add_hl(highlights, group, row, start_col, end_col, priority, hl_mode)
  if not group then return end
  local item = { group = group, row = row, start_col = start_col, end_col = end_col, priority = priority }
  if hl_mode then
    item.hl_mode = hl_mode
  end
  highlights[#highlights + 1] = item
end

function M.from_lines(old_lines, new_lines, opts)
  opts = opts or {}
  local old_l = norm(vim.deepcopy(old_lines))
  local new_l = norm(vim.deepcopy(new_lines))
  local ok, hunks = pcall(vim.diff, table.concat(old_l, "\n"), table.concat(new_l, "\n"), {
    result_type = "indices",
    algorithm = opts.algorithm or "myers",
  })
  local rows = trim(rows_from_hunks(old_l, new_l, (ok and type(hunks) == "table") and hunks or {}, opts.old_start or 1, opts.new_start or 1), opts.context)
  if #rows == 0 then
    return { "No changes" }, {}, 1
  end
  local mo, mn = 1, 1
  for _, r in ipairs(rows) do
    if r.old and r.old > mo then mo = r.old end
    if r.new and r.new > mn then mn = r.new end
  end
  local w_old, w_new = math.max(#tostring(mo), 2), math.max(#tostring(mn), 2)
  local lines, highlights, focus = {}, {}, 1

  for i, r in ipairs(rows) do
    local line = string.format(" %" .. w_old .. "s %" .. w_new .. "s  %s %s", r.old or "", r.new or "", r.sign, r.text or "")
    local row = i - 1
    local num_end_col = w_old + w_new + 3
    local style = STYLE_BY_SIGN[r.sign]

    add_hl(highlights, "LineNr", row, 0, num_end_col, PRIO_NUM - 1, "replace")
    if style then
      if focus == 1 then focus = i end
      line = line .. string.rep(" ", CONTENT_PAD)
      add_hl(highlights, style.num, row, 0, num_end_col, PRIO_NUM, "replace")
      add_hl(highlights, style.sign, row, num_end_col, num_end_col + 3, PRIO_SIGN, "replace")
      add_hl(highlights, style.content, row, num_end_col + 3, #line, PRIO_CONTENT, "combine")
    end
    lines[i] = line
  end
  return lines, highlights, focus
end
return M
