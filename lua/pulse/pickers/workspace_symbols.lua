local M = {}
local util = require("pulse.util")

local SymbolKind = vim.lsp.protocol.SymbolKind or {}
local TS_KIND = { ["function"] = 12, ["method"] = 6, ["class"] = 5, ["interface"] = 11, ["enum"] = 10, ["struct"] = 23, ["type"] = 13 }
local NODE_KIND_PATTERNS = { "function", "method", "class", "interface", "enum", "struct", "type", "declaration" }
local function kname(k) return SymbolKind[k] or "Symbol" end
local function depth(container)
  if not container or container == "" then return 0 end
  local p = vim.split(container:gsub("::", "."), ".", { plain = true, trimempty = true })
  return #p
end
local function sort_items(items)
  table.sort(items, function(a, b)
    if a.filename == b.filename then
      if a.lnum == b.lnum then return a.col < b.col end
      return a.lnum < b.lnum
    end
    return (a.symbol or "") < (b.symbol or "")
  end)
end

local function mk_item(name, kind, container, filename, line, col, depth_override)
  local c = container or ""
  return {
    kind = "workspace_symbol",
    symbol = name or "",
    symbol_kind = kind or 0,
    symbol_kind_name = kname(kind or 0),
    container = c,
    depth = (type(depth_override) == "number") and math.max(depth_override, 0) or depth(c),
    filename = filename or "",
    lnum = (line or 0) + 1,
    col = (col or 0) + 1,
  }
end

local function is_symbol_node(nt)
  for _, p in ipairs(NODE_KIND_PATTERNS) do
    if nt:find(p) then return true end
  end
  return false
end

local function lsp_fetch(query, cb)
  local pending, out = 0, {}
  for _, c in ipairs(vim.lsp.get_active_clients()) do
    if c.supports_method and c.supports_method("workspace/symbol") then
      pending = pending + 1
      c.request("workspace/symbol", { query = query or "" }, function(_, result)
        for _, s in ipairs(result or {}) do
          local loc, st = s.location or {}, (s.location and s.location.range and s.location.range.start) or {}
          out[#out + 1] = mk_item(s.name, s.kind, s.containerName, loc.uri and vim.uri_to_fname(loc.uri) or "", st.line, st.character)
        end
        pending = pending - 1
        if pending == 0 then sort_items(out); cb(out) end
      end, 0)
    end
  end
  if pending == 0 then cb(nil) end
end

local function ts_kind(nt)
  for key, v in pairs(TS_KIND) do if nt:find(key) then return v end end
  return 13
end
local function ts_name(text)
  local s = vim.trim((text or ""):gsub("\n.*$", ""))
  if s == "" then return "" end
  return s:match("<%s*([%w%._:-]+)") or s:match("([%a_][%w_]*)%s*[%(<:{=]") or s:match("([%a_][%w_]*)") or ""
end
local function ts_items(query)
  local match = util.make_matcher(query or "", { ignore_case = true, plain = true })
  local out, cwd = {}, vim.fn.getcwd()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted then
      local f = vim.api.nvim_buf_get_name(b)
      if f ~= "" and f:sub(1, #cwd) == cwd then
        local ok, p = pcall(vim.treesitter.get_parser, b)
        if ok and p then
          local okp, trees = pcall(function() return p:parse() end)
          local root = okp and trees and trees[1] and trees[1]:root() or nil
          if root then
            local function walk(n, d)
              local nt = n:type() or ""
              if is_symbol_node(nt) then
                local txt = vim.treesitter.get_node_text(n, b)
                if type(txt) == "table" then txt = table.concat(txt, "") end
                local name = ts_name(txt)
                if name ~= "" and match(name) then
                  local r, c = n:range()
                  local k = ts_kind(nt)
                  out[#out + 1] = mk_item(name, k, "", f, r, c, d)
                end
              end
              for ch in n:iter_children() do walk(ch, d + 1) end
            end
            walk(root, 0)
          end
        end
      end
    end
  end
  sort_items(out)
  return out
end

function M.seed(ctx)
  return { symbols = {}, last_query = nil, request_id = 0, on_update = ctx and ctx.on_update }
end

function M.items(state, query)
  local q = query or ""
  local match = util.make_matcher(q, { ignore_case = true, plain = true })
  if state.last_query ~= q then
    state.last_query, state.request_id = q, state.request_id + 1
    local rid = state.request_id
    lsp_fetch(q, function(items)
      if rid ~= state.request_id then return end
      state.symbols = items or ts_items(q)
      if state.on_update then vim.schedule(state.on_update) end
    end)
  end
  if q == "" then return state.symbols end
  local out = {}
  for _, it in ipairs(state.symbols or {}) do
    local hay = table.concat({ it.symbol or "", it.symbol_kind_name or "", it.container or "", it.filename or "" }, " ")
    if match(hay) then out[#out + 1] = it end
  end
  return out
end

return M
