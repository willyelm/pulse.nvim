local common = require("pulse.pickers.common")

local M = {}

function M.title()
  return "Workspace Symbols"
end

local SymbolKind = vim.lsp.protocol.SymbolKind or {}

local function kind_name(kind)
  return SymbolKind[kind] or "Symbol"
end

local function depth_from_container(container)
  if not container or container == "" then
    return 0
  end
  local c = container:gsub("::", ".")
  local parts = vim.split(c, ".", { plain = true, trimempty = true })
  return math.max(#parts - 1, 0)
end

local function fetch_async(query, cb)
  local params = { query = query or "" }
  local acc = {}
  local pending = 0

  for _, client in ipairs(vim.lsp.get_active_clients()) do
    if client.supports_method and client.supports_method("workspace/symbol") then
      pending = pending + 1
      client.request("workspace/symbol", params, function(_, result)
        for _, item in ipairs(result or {}) do
          local filename = item.location and item.location.uri and vim.uri_to_fname(item.location.uri) or ""
          local pos = item.location and item.location.range and item.location.range.start or {}
          local container = item.containerName or ""
          table.insert(acc, {
            kind = "workspace_symbol",
            symbol = item.name or "",
            symbol_kind = item.kind or 0,
            symbol_kind_name = kind_name(item.kind or 0),
            container = container,
            depth = depth_from_container(container),
            filename = filename,
            lnum = (pos.line or 0) + 1,
            col = (pos.character or 0) + 1,
          })
        end
        pending = pending - 1
        if pending <= 0 and cb then
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
    queried = {},
    on_update = ctx and ctx.on_update or nil,
  }

  fetch_async("", function(items)
    state.symbols = items
    state.queried[""] = true
    if state.on_update then
      vim.schedule(state.on_update)
    end
  end)

  return state
end

function M.items(state, query)
  local q = query or ""

  if q ~= "" and not state.queried[q] then
    state.queried[q] = true
    fetch_async(q, function(items)
      if #items >= #state.symbols then
        state.symbols = items
      end
      if state.on_update then
        vim.schedule(state.on_update)
      end
    end)
  end

  if q == "" then
    return state.symbols
  end

  local out = {}
  for _, s in ipairs(state.symbols or {}) do
    local hay = table.concat({ s.symbol or "", s.symbol_kind_name or "", s.container or "", s.filename or "" }, " ")
    if common.has_ci(hay, q) then
      table.insert(out, s)
    end
  end
  return out
end

return M
