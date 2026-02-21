local M = {}

local DEBOUNCE_MS = 60
local MAX_RESULTS = 400
local uv = vim.uv or vim.loop

function M.title()
  return "Live Grep"
end

local function notify_update(state)
  if type(state.on_update) ~= "function" then
    return
  end
  if state.update_scheduled then
    return
  end
  state.update_scheduled = true
  vim.schedule(function()
    state.update_scheduled = false
    if type(state.on_update) == "function" then
      state.on_update()
    end
  end)
end

local function stop_job(state)
  if state.job and state.job > 0 then
    pcall(vim.fn.jobstop, state.job)
  end
  state.job = nil
end

local function stop_timer(state)
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = nil
end

local function clear_results(state)
  state.items = {}
  state.pending_items = nil
  state.limit_reached = false
end

local function cancel_work(state)
  stop_timer(state)
  stop_job(state)
end

local function append_lines(state, lines, query)
  for _, line in ipairs(lines or {}) do
    if line and line ~= "" then
      local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
      if path and lnum and col then
        state.pending_items[#state.pending_items + 1] = {
          kind = "live_grep",
          path = path,
          filename = path,
          lnum = tonumber(lnum),
          col = tonumber(col),
          text = text or "",
          query = query,
        }
      end
    end
    if #state.pending_items >= MAX_RESULTS then
      state.limit_reached = true
      break
    end
  end
end

local function parse_stdout_chunk(state, data, query)
  if not data or #data == 0 then
    return
  end
  append_lines(state, data, query)
  if #state.pending_items > 0 then
    state.items = vim.list_slice(state.pending_items, 1, MAX_RESULTS)
    notify_update(state)
  end
end

local function start_search(state, query, token)
  stop_job(state)
  state.pending_items = {}
  state.limit_reached = false

  local cmd = {
    "rg",
    "--vimgrep",
    "--hidden",
    "--glob",
    "!**/.git/*",
    "--line-buffered",
    "--smart-case",
    "--color",
    "never",
    "--max-columns",
    "300",
    query,
    state.cwd or ".",
  }

  state.job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if token ~= state.token then
        return
      end
      parse_stdout_chunk(state, data, query)
      if state.limit_reached then
        stop_job(state)
      end
    end,
    on_exit = function(_, code)
      if token ~= state.token then
        return
      end
      state.job = nil
      if code == 0 or code == 1 or state.limit_reached then
        state.items = vim.list_slice(state.pending_items or {}, 1, MAX_RESULTS)
      else
        state.items = {}
      end
      state.pending_items = nil
      notify_update(state)
    end,
  })

  if state.job <= 0 then
    state.job = nil
    clear_results(state)
    notify_update(state)
  end
end

function M.seed(ctx)
  return {
    on_update = ctx and ctx.on_update or nil,
    cwd = (ctx and ctx.cwd) or vim.fn.getcwd(),
    query = "",
    items = {},
    pending_items = nil,
    token = 0,
    job = nil,
    timer = nil,
    limit_reached = false,
    update_scheduled = false,
  }
end

function M.items(state, query)
  local q = vim.trim(query or "")
  if q == "" then
    state.query = ""
    clear_results(state)
    state.token = state.token + 1
    cancel_work(state)
    return {}
  end

  if q ~= state.query then
    state.query = q
    state.token = state.token + 1
    local token = state.token

    stop_timer(state)
    state.timer = uv.new_timer()
    state.timer:start(DEBOUNCE_MS, 0, function()
      vim.schedule(function()
        if token ~= state.token or state.query ~= q then
          return
        end
        start_search(state, q, token)
      end)
      stop_timer(state)
    end)
  end

  return state.items
end

return M
