local M = {}

function M.title()
  return "Workspace Symbols"
end

local SymbolKind = vim.lsp.protocol.SymbolKind or {}

local function has_ci(haystack, needle)
  if needle == "" then
    return true
  end
  return string.find(string.lower(haystack or ""), string.lower(needle), 1, true) ~= nil
end

local function kind_name(kind)
  return SymbolKind[kind] or "Symbol"
end

local function depth_from_container(container)
  if not container or container == "" then
    return 0
  end
  local parts = vim.split(container:gsub("::", "."), ".", { plain = true, trimempty = true })
  return math.max(#parts - 1, 0)
end

local function sort_items(items)
  table.sort(items, function(a, b)
    if a.filename == b.filename then
      if a.lnum == b.lnum then
        return a.col < b.col
      end
      return a.lnum < b.lnum
    end
    return a.filename < b.filename
  end)
end

local function fetch_async(query, cb)
  local params = { query = query or "" }
  local pending = 0
  local acc = {}

  for _, client in ipairs(vim.lsp.get_active_clients()) do
    if client.supports_method and client.supports_method("workspace/symbol") then
      pending = pending + 1
      client.request("workspace/symbol", params, function(_, result)
        for _, item in ipairs(result or {}) do
          local filename = item.location and item.location.uri and vim.uri_to_fname(item.location.uri) or ""
          local pos = item.location and item.location.range and item.location.range.start or {}
          local container = item.containerName or ""

          acc[#acc + 1] = {
            kind = "workspace_symbol",
            symbol = item.name or "",
            symbol_kind = item.kind or 0,
            symbol_kind_name = kind_name(item.kind or 0),
            container = container,
            depth = depth_from_container(container),
            filename = filename,
            lnum = (pos.line or 0) + 1,
            col = (pos.character or 0) + 1,
          }
        end

        pending = pending - 1
        if pending == 0 and cb then
          sort_items(acc)
          cb(acc)
        end
      end, 0)
    end
  end

  if pending == 0 and cb then
    cb({})
  end
end

function M.seed(ctx)
  local state = {
    symbols = {},
    last_query = nil,
    request_id = 0,
    on_update = ctx and ctx.on_update or nil,
  }

  state.request_id = state.request_id + 1
  local rid = state.request_id
  fetch_async("", function(items)
    if rid ~= state.request_id then
      return
    end
    state.symbols = items
    if state.on_update then
      vim.schedule(state.on_update)
    end
  end)

  return state
end

function M.items(state, query)
  local q = query or ""

  if state.last_query ~= q then
    state.last_query = q
    state.request_id = state.request_id + 1
    local rid = state.request_id

    fetch_async(q, function(items)
      if rid ~= state.request_id then
        return
      end
      state.symbols = items
      if state.on_update then
        vim.schedule(state.on_update)
      end
    end)
  end

  if q == "" then
    return state.symbols
  end

  local out = {}
  for _, item in ipairs(state.symbols or {}) do
    if has_ci(table.concat({ item.symbol or "", item.symbol_kind_name or "", item.container or "", item.filename or "" }, " "), q) then
      out[#out + 1] = item
    end
  end
  return out
end

return M
