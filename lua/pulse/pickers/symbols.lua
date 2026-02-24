local M = {}
local util = require("pulse.util")

local SymbolKind = vim.lsp.protocol.SymbolKind or {}
local NODE_KIND_PATTERNS = { "function", "method", "class", "interface", "enum", "struct", "type", "declaration" }

local function kind_name(kind) return (type(kind) == "number" and SymbolKind[kind]) or ((type(kind) == "string" and kind ~= "") and kind) or "Symbol" end

local function sort_by_line(items)
  table.sort(items, function(a, b)
    if (a.lnum or 0) == (b.lnum or 0) then
      return (a.col or 0) < (b.col or 0)
    end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
end

local function make_symbol(name, kind, depth, line, col, filename)
  return {
    kind = "symbol",
    symbol = tostring(name or ""):gsub("\n.*$", ""),
    symbol_kind = kind or 0,
    symbol_kind_name = kind_name(kind or 0),
    depth = depth or 0,
    lnum = (line or 0) + 1,
    col = (col or 0) + 1,
    filename = filename or "",
  }
end

local function is_symbol_node(node_type)
  for _, p in ipairs(NODE_KIND_PATTERNS) do
    if node_type:find(p) then
      return true
    end
  end
  return false
end

local function flatten_document_symbols(result, bufnr)
  local out, filename = {}, vim.api.nvim_buf_get_name(bufnr)
  local function walk(nodes, depth)
    for _, s in ipairs(nodes or {}) do
      local r = s.selectionRange or s.range
      if r and r.start and s.name and s.name ~= "" then
        out[#out + 1] = make_symbol(s.name, s.kind, depth, r.start.line, r.start.character, filename)
        walk(s.children, depth + 1)
      else
        walk(s.children, depth)
      end
    end
  end

  walk(result, 0); sort_by_line(out)
  return out
end

local function flatten_symbol_information(result)
  local out = {}
  for _, s in ipairs(result or {}) do
    local loc = s.location
    local start = loc and loc.range and loc.range.start
    if start and s.name and s.name ~= "" then
      out[#out + 1] = make_symbol(s.name, s.kind, 0, start.line, start.character, loc.uri and vim.uri_to_fname(loc.uri) or "")
    end
  end
  sort_by_line(out)
  return out
end

local function lsp_symbols(bufnr, result)
  if type(result) ~= "table" or #result == 0 then
    return {}
  end
  if result[1] and result[1].location then
    return flatten_symbol_information(result)
  end
  return flatten_document_symbols(result, bufnr)
end

local function treesitter_fallback(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then return {} end
  local ok2, trees = pcall(function() return parser:parse() end)
  if not ok2 or not (trees and trees[1]) then return {} end
  local root = trees[1]:root()
  if not root then return {} end

  local out, filename = {}, vim.api.nvim_buf_get_name(bufnr)

  local function walk(node)
    local t = node:type() or ""
    if is_symbol_node(t) then
      local sr, sc = node:range()
      local text = vim.treesitter.get_node_text(node, bufnr)
      if type(text) == "table" then
        text = table.concat(text, "")
      end
      local name = vim.trim(tostring(text or ""):gsub("\n.*$", ""))
      if name ~= "" then
        out[#out + 1] = make_symbol(name, 0, 0, sr, sc, filename)
      end
    end

    for child in node:iter_children() do
      walk(child)
    end
  end

  walk(root); sort_by_line(out)
  return out
end

function M.seed(ctx)
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local state = { symbols = treesitter_fallback(bufnr) }

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(_, result)
    local mapped = lsp_symbols(bufnr, result)
    if #mapped > 0 then
      state.symbols = mapped
      if ctx and type(ctx.on_update) == "function" then
        vim.schedule(ctx.on_update)
      end
    end
  end)

  return state
end

function M.items(state, query)
  local symbols = state.symbols or {}
  query = query or ""
  if query == "" then
    return symbols
  end

  local match = util.make_matcher(query, { ignore_case = true, plain = true })
  local out = {}
  for _, s in ipairs(symbols) do
    local hay = table.concat({ s.symbol or "", s.symbol_kind_name or "", s.filename or "" }, " ")
    if match(hay) then
      out[#out + 1] = s
    end
  end
  return out
end

function M.total_count(state)
  return #(state.symbols or {})
end

return M
