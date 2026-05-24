local M = {}
local context = require("pulse.context")
local pulse = require("pulse")
local CACHE = {}

M.name = "symbols"
M.icon = "󰘧"
M.actions = {
	{
		key = "<CR>",
		name = "jump",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.jump(ctx.item)
				ctx.close()
				return false
			end
		end,
	},
	{
		key = "<Tab>",
		name = "preview",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.preview(ctx.item)
			end
		end,
	},
}
M.panels = {
	{ start = "@", name = "symbols", label = "Symbols", contexts = { "buffer" } },
	{ start = "#", name = "workspace_symbols", label = "Workspace Symbols", contexts = { "workspace" } },
}

M.view = false

local SymbolKind = vim.lsp.protocol.SymbolKind or {}
local NODE_KINDS = {
	["function"] = true,
	method = true,
	class = true,
	interface = true,
	enum = true,
	struct = true,
	type = true,
	declaration = true,
}

local function kind_name(kind)
	return (type(kind) == "number" and SymbolKind[kind])
		or ((type(kind) == "string" and kind ~= "") and kind)
		or "Symbol"
end

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
	for kind in pairs(NODE_KINDS) do
		if node_type:find(kind) then
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

	walk(result, 0)
	sort_by_line(out)
	return out
end

local function flatten_symbol_information(result)
	local out = {}
	for _, s in ipairs(result or {}) do
		local loc = s.location
		local start = loc and loc.range and loc.range.start
		if start and s.name and s.name ~= "" then
			out[#out + 1] =
				make_symbol(s.name, s.kind, 0, start.line, start.character, loc.uri and vim.uri_to_fname(loc.uri) or "")
		end
	end
	sort_by_line(out)
	return out
end

local function symbol_location(symbol)
	local loc = symbol and symbol.location or nil
	if type(loc) ~= "table" then
		return nil, nil
	end
	local uri = loc.uri or loc.targetUri
	local range = loc.range or loc.targetSelectionRange or loc.targetRange
	return uri, range
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

local function lsp_workspace_symbols(bufnr, query, cb)
	local pending, out = 0, {}
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if client:supports_method("workspace/symbol") then
			pending = pending + 1
			local root = client.root_dir or vim.fn.getcwd()
			pcall(function()
				client:request("workspace/symbol", { query = query or "" }, function(_, result)
					for _, symbol in ipairs(result or {}) do
						local uri, range = symbol_location(symbol)
						if symbol.name and uri then
							local filename = vim.uri_to_fname(uri)
							if filename:sub(1, #root) == root then
								local start = (range and range.start) or {}
								out[#out + 1] = {
									kind = "workspace_symbol",
									symbol = symbol.name,
									filename = filename,
									depth = 1,
									symbol_kind_name = SymbolKind[symbol.kind] or "Symbol",
									container = symbol.containerName or "",
									lnum = (start.line or 0) + 1,
									col = (start.character or 0) + 1,
								}
							end
						end
					end
					pending = pending - 1
					if pending == 0 then
						cb(out)
					end
				end, bufnr)
			end)
		end
	end
	if pending == 0 then
		cb({})
	end
end

local function sync_lsp_symbols(bufnr, timeout_ms)
	local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
	local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, timeout_ms or 40) or {}
	local merged = {}
	for _, resp in pairs(responses) do
		local mapped = lsp_symbols(bufnr, resp and resp.result)
		for _, item in ipairs(mapped) do
			merged[#merged + 1] = item
		end
	end
	if #merged > 0 then
		sort_by_line(merged)
	end
	return merged
end

local function treesitter_fallback(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok or not parser then
		return {}
	end
	local ok2, trees = pcall(function()
		return parser:parse()
	end)
	if not ok2 or not (trees and trees[1]) then
		return {}
	end
	local root = trees[1]:root()
	if not root then
		return {}
	end

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

	walk(root)
	sort_by_line(out)
	return out
end

local function has_document_symbol_client(bufnr)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if client:supports_method("textDocument/documentSymbol") then
			return true
		end
	end
	return false
end

local function treesitter_workspace_symbols(query)
	local match = pulse.make_matcher(query or "", { ignore_case = true, plain = true })
	local out, cwd = {}, vim.fn.getcwd()
	local patterns = { "function", "method", "class", "interface", "enum", "struct", "type", "declaration" }

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buflisted then
			local filename = vim.api.nvim_buf_get_name(bufnr)
			if filename ~= "" and filename:sub(1, #cwd) == cwd then
				local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
				if ok and parser then
					local ok2, trees = pcall(function()
						return parser:parse()
					end)
					local root = ok2 and trees and trees[1] and trees[1]:root()
					if root then
						local function walk(node)
							local node_type = node:type() or ""
							for _, pattern in ipairs(patterns) do
								if node_type:find(pattern) then
									local text = vim.treesitter.get_node_text(node, bufnr)
									local name = vim.trim(type(text) == "table" and table.concat(text, "") or text):gsub("\n.*$", "")
									if name ~= "" and match(name) then
										local line, col = node:range()
										out[#out + 1] = {
											kind = "workspace_symbol",
											symbol = name,
											filename = filename,
											depth = 1,
											symbol_kind_name = "Symbol",
											container = "",
											lnum = line + 1,
											col = col + 1,
										}
									end
									break
								end
							end
							for child in node:iter_children() do
								walk(child)
							end
						end
						walk(root)
					end
				end
			end
		end
	end

	return out
end

local function cached_symbols(bufnr)
	if not context.valid_bufnr(bufnr) then
		return nil
	end
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = CACHE[bufnr]
	if cached and cached.tick == tick then
		return cached.symbols
	end
	return nil
end

local function store_symbols(bufnr, symbols)
	if not context.valid_bufnr(bufnr) then
		return symbols
	end
	CACHE[bufnr] = {
		tick = vim.api.nvim_buf_get_changedtick(bufnr),
		symbols = symbols,
	}
	return symbols
end

function M.init(ctx)
	local bufnr = context.resolve_bufnr(ctx)
	local state = {
		bufnr = bufnr,
		symbols = {},
		input_context = nil,
		workspace_symbols = {},
		workspace_query = nil,
		workspace_request_id = 0,
		on_update = ctx and ctx.on_update,
	}

	if not bufnr then
		return state
	end

	pcall(vim.fn.bufload, bufnr)
	state.input_context = context.input_context(ctx, bufnr)
	local use_lsp = has_document_symbol_client(bufnr)
	local cached = cached_symbols(bufnr)
	state.symbols = cached or {}
	if not cached then
		if use_lsp then
			state.symbols = sync_lsp_symbols(bufnr, 40)
		end
		if #state.symbols == 0 and not use_lsp then
			state.symbols = treesitter_fallback(bufnr)
		end
		store_symbols(bufnr, state.symbols)
	end
	if use_lsp then
		local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
		vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(_, result)
			local mapped = lsp_symbols(bufnr, result)
			if #mapped == 0 then
				return
			end
			state.symbols = store_symbols(bufnr, mapped)
			if state.on_update then
				vim.schedule(state.on_update)
			end
		end)
	end

	return state
end

function M.input_context(state, scoped)
	if scoped and scoped.kind == "file" then
		return scoped
	end
	return state and state.input_context or nil
end

local function buffer_items(state, query)
	local symbols = state.symbols or {}
	query = query or ""
	if query == "" then
		return symbols
	end

	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	local out = {}
	for _, s in ipairs(symbols) do
		local hay = table.concat({ s.symbol or "", s.symbol_kind_name or "", s.filename or "" }, " ")
		if match(hay) then
			out[#out + 1] = s
		end
	end
	return out
end

local function workspace_items(state, query)
	query = query or ""
	if state.workspace_query ~= query then
		state.workspace_query = query
		state.workspace_request_id = state.workspace_request_id + 1
		state.workspace_symbols = {}
		local request_id = state.workspace_request_id
		local bufnr = state.bufnr or vim.api.nvim_get_current_buf()
		lsp_workspace_symbols(bufnr, query, function(items)
			if request_id ~= state.workspace_request_id then
				return
			end
			state.workspace_symbols = (#items > 0) and items or treesitter_workspace_symbols(query)
			if state.on_update then
				vim.schedule(state.on_update)
			end
		end)
	end

	local by_file, cwd, out = {}, vim.fn.getcwd(), {}
	for _, item in ipairs(state.workspace_symbols or {}) do
		local filename = item.filename or ""
		by_file[filename] = by_file[filename] or {}
		by_file[filename][#by_file[filename] + 1] = item
	end

	local files = vim.tbl_keys(by_file)
	table.sort(files)
	for _, file in ipairs(files) do
		local items = by_file[file]
		local rel = file:sub(1, #cwd) == cwd and file:sub(#cwd + 2) or file
		out[#out + 1] = { kind = "header", label = rel, path = file }
		for _, item in ipairs(items) do
			out[#out + 1] = item
		end
	end

	return out
end

function M.items(state, query, panel_name)
	if panel_name == "workspace_symbols" then
		return workspace_items(state, query)
	end
	return buffer_items(state, query)
end

function M.total_count(state, panel_name)
	if panel_name == "workspace_symbols" then
		return #(state.workspace_symbols or {})
	end
	return #(state.symbols or {})
end

return M
