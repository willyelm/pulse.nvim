local common = require("pulse.pickers.common")

local M = {}

function M.title()
  return "Symbols"
end

local function symbol_kind_for_node(node_type)
  if node_type:find("function") or node_type:find("method") then
    return 12
  end
  if node_type:find("class") then
    return 5
  end
  if node_type:find("interface") then
    return 11
  end
  if node_type:find("struct") then
    return 23
  end
  if node_type:find("enum") then
    return 10
  end
  return 13
end

local function collect_treesitter_symbols(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return {}
  end

  local tree = parser:parse()[1]
  if not tree then
    return {}
  end

  local out = {}
  local root = tree:root()

  local function walk(node)
    if not node then
      return
    end
    local t = node:type() or ""
    if t:find("function") or t:find("method") or t:find("class") or t:find("interface") or t:find("struct") or t:find("enum") then
      local sr, sc, er, ec = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr) or ""
      local first = vim.split(text, "\n", { plain = true })[1] or ""
      first = vim.trim(first)
      if first ~= "" then
        table.insert(out, {
          kind = "symbol",
          symbol = first,
          symbol_kind = symbol_kind_for_node(t),
          lnum = sr + 1,
          col = sc + 1,
          filename = vim.api.nvim_buf_get_name(bufnr),
        })
      end
      if #out > 300 then
        return
      end
    end

    for child in node:iter_children() do
      walk(child)
      if #out > 300 then
        return
      end
    end
  end

  walk(root)
  return out
end

local function flatten_lsp_symbols(items, out)
  out = out or {}
  for _, item in ipairs(items or {}) do
    local name = item.name or ""
    local kind = item.kind or 0
    local range = item.selectionRange or item.range
    if range and range.start then
      table.insert(out, {
        kind = "symbol",
        symbol = name,
        symbol_kind = kind,
        lnum = (range.start.line or 0) + 1,
        col = (range.start.character or 0) + 1,
        filename = vim.api.nvim_buf_get_name(0),
      })
    elseif item.location and item.location.range and item.location.range.start then
      table.insert(out, {
        kind = "symbol",
        symbol = name,
        symbol_kind = kind,
        lnum = (item.location.range.start.line or 0) + 1,
        col = (item.location.range.start.character or 0) + 1,
        filename = vim.uri_to_fname(item.location.uri),
      })
    end
    if item.children then
      flatten_lsp_symbols(item.children, out)
    end
  end
  return out
end

local function dedupe(symbols)
  local out, seen = {}, {}
  for _, s in ipairs(symbols) do
    local key = table.concat({ s.symbol or "", s.filename or "", tostring(s.lnum or 0), tostring(s.col or 0) }, "|")
    if not seen[key] then
      seen[key] = true
      table.insert(out, s)
    end
  end
  return out
end

function M.seed(ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = {
    symbols = collect_treesitter_symbols(bufnr),
  }

  local params = { textDocument = vim.lsp.util.make_text_document_params() }
  vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(_, result)
    if not result then
      return
    end
    local merged = vim.list_extend(vim.deepcopy(state.symbols), flatten_lsp_symbols(result, {}))
    state.symbols = dedupe(merged)
    if ctx and type(ctx.on_update) == "function" then
      vim.schedule(ctx.on_update)
    end
  end)

  return state
end

function M.items(state, query)
  local symbols = state.symbols or {}
  if query == "" then
    return symbols
  end
  local out = {}
  for _, s in ipairs(symbols) do
    local hay = table.concat({ s.symbol or "", s.container or "", s.filename or "" }, " ")
    if common.has_ci(hay, query) then
      table.insert(out, s)
    end
  end
  return out
end

return M
