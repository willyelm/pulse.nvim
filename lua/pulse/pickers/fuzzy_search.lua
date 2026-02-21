local M = {}

local MAX_RESULTS = 400

function M.title()
  return "Fuzzy Search"
end

local function refresh_lines(state)
  local bufnr = state.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    state.lines = {}
    state.line_count = 0
    state.filename = ""
    state.tick = 0
    return
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if tick == state.tick then
    return
  end

  state.tick = tick
  state.lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  state.line_count = #state.lines
  state.filename = vim.api.nvim_buf_get_name(bufnr)
end

local function fuzzy_score(haystack, needle)
  if needle == "" then
    return nil
  end
  local h = string.lower(haystack or "")
  local n = string.lower(needle)
  local hlen, nlen = #h, #n
  if nlen == 0 or hlen == 0 then
    return nil
  end

  local pos = 1
  local score = 0
  local first_idx = nil
  local prev_idx = nil

  for i = 1, nlen do
    local c = n:sub(i, i)
    local idx = h:find(c, pos, true)
    if not idx then
      return nil
    end
    if not first_idx then
      first_idx = idx
    end
    score = score + 1
    if prev_idx and idx == prev_idx + 1 then
      score = score + 3
    end
    prev_idx = idx
    pos = idx + 1
  end

  score = score - (first_idx or 1) * 0.01
  return score, first_idx or 1
end

function M.seed(ctx)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  return {
    bufnr = bufnr,
    filename = vim.api.nvim_buf_get_name(bufnr),
    lines = {},
    line_count = 0,
    tick = -1,
  }
end

function M.items(state, query)
  refresh_lines(state)
  local q = vim.trim(query or "")
  if q == "" then
    return {}
  end

  local out = {}
  for i, line in ipairs(state.lines or {}) do
    local score, col = fuzzy_score(line, q)
    if score then
      out[#out + 1] = {
        kind = "fuzzy_search",
        filename = state.filename,
        path = state.filename,
        lnum = i,
        col = col,
        text = line,
        query = q,
        score = score,
      }
    end
  end

  table.sort(out, function(a, b)
    if a.score == b.score then
      return (a.lnum or 0) < (b.lnum or 0)
    end
    return (a.score or 0) > (b.score or 0)
  end)

  if #out > MAX_RESULTS then
    local trimmed = {}
    for i = 1, MAX_RESULTS do
      trimmed[i] = out[i]
    end
    return trimmed
  end

  return out
end

function M.total_count(state)
  refresh_lines(state)
  return state.line_count or 0
end

return M
