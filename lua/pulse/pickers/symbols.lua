local common = require("pulse.pickers.common")

local M = {}

function M.title()
  return "Symbols"
end

local SymbolKind = vim.lsp.protocol.SymbolKind or {}

local function kind_name(kind)
  if type(kind) == "number" then
    return SymbolKind[kind] or "Symbol"
  end
  if type(kind) == "string" and kind ~= "" then
    return kind
  end
  return "Symbol"
end

local function map_loclist_items(items)
  local out = {}
  for _, it in ipairs(items or {}) do
    local text = tostring(it.text or "")
    local name = vim.trim(text:gsub("^%b[]%s*", ""))
    if name == "" then
      name = text
    end

    out[#out + 1] = {
      kind = "symbol",
      symbol = name,
      symbol_kind = tonumber(it.kind) or 0,
      symbol_kind_name = kind_name(it.kind),
      depth = 0,
      lnum = it.lnum or 1,
      col = it.col or 1,
      filename = it.filename or (it.bufnr and vim.api.nvim_buf_get_name(it.bufnr)) or "",
    }
  end
  return out
end

local function treesitter_fallback(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return {}
  end

  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or not trees or not trees[1] then
    return {}
  end

  local root = trees[1]:root()
  if not root then
    return {}
  end

  local out = {}
  local filename = vim.api.nvim_buf_get_name(bufnr)

  local function walk(node)
    local t = node:type() or ""
    if t:find("function") or t:find("method") or t:find("class") or t:find("interface") or t:find("enum")
      or t:find("struct") or t:find("type") or t:find("declaration") then
      local sr, sc = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr)
      if type(text) == "table" then
        text = table.concat(text, "")
      end
      local name = vim.trim(tostring(text or ""):gsub("\n.*$", ""))
      if name ~= "" then
        out[#out + 1] = {
          kind = "symbol",
          symbol = name,
          symbol_kind = 0,
          symbol_kind_name = "Symbol",
          depth = 0,
          lnum = sr + 1,
          col = sc + 1,
          filename = filename,
        }
      end
    end

    for child in node:iter_children() do
      walk(child)
    end
  end

  walk(root)
  table.sort(out, function(a, b)
    if a.lnum == b.lnum then
      return (a.col or 0) < (b.col or 0)
    end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
  return out
end

function M.seed(ctx)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = { symbols = treesitter_fallback(bufnr) }

  vim.lsp.buf.document_symbol({
    on_list = function(o)
      local items = o and o.items or {}
      table.sort(items, function(a, b)
        if (a.lnum or 0) == (b.lnum or 0) then
          return (a.col or 0) < (b.col or 0)
        end
        return (a.lnum or 0) < (b.lnum or 0)
      end)

      local mapped = map_loclist_items(items)
      if #mapped > 0 then
        state.symbols = mapped
        if ctx and type(ctx.on_update) == "function" then
          vim.schedule(ctx.on_update)
        end
      end
    end,
  })

  return state
end

function M.items(state, query)
  local symbols = state.symbols or {}
  if query == "" then
    return symbols
  end

  local out = {}
  for _, s in ipairs(symbols) do
    local hay = table.concat({ s.symbol or "", s.symbol_kind_name or "", s.filename or "" }, " ")
    if common.has_ci(hay, query) then
      out[#out + 1] = s
    end
  end
  return out
end

return M
