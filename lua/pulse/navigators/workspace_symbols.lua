local M = {}
local pulse = require("pulse")

M.mode = {
	name = "workspace_symbol",
	icon = "󰒕",
	actions = {
		{
			key = "<CR>",
			name = "Open",
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
			name = "Preview",
			when = function(ctx)
				return ctx and ctx.item ~= nil
			end,
			run = function(ctx)
				if ctx and ctx.item then
					ctx.preview(ctx.item)
				end
			end,
		},
	},
}
M.panels = {
	{ start = "#", name = "workspace_symbol", label = "Workspace Symbols", scopes = { "workspace" } },
}

M.context = false

local SymbolKind = vim.lsp.protocol.SymbolKind or {}

local function symbol_location(symbol)
	local loc = symbol and symbol.location or nil
	if type(loc) ~= "table" then
		return nil, nil
	end
	local uri = loc.uri or loc.targetUri
	local range = loc.range or loc.targetSelectionRange or loc.targetRange
	return uri, range
end

local function lsp_fetch(bufnr, query, cb)
	local pending, out = 0, {}
	for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if c:supports_method("workspace/symbol") then
			pending = pending + 1
			local root = c.root_dir or vim.fn.getcwd()
			pcall(function()
				c:request("workspace/symbol", { query = query or "" }, function(_, result)
					for _, s in ipairs(result or {}) do
						local uri, range = symbol_location(s)
						if s.name and uri then
							local f = vim.uri_to_fname(uri)
							if f:sub(1, #root) == root then
								local st = (range and range.start) or {}
								table.insert(out, {
									kind = "workspace_symbol",
									symbol = s.name,
									filename = f,
									depth = 1,
									symbol_kind_name = SymbolKind[s.kind] or "Symbol",
									container = s.containerName or "",
									lnum = (st.line or 0) + 1,
									col = (st.character or 0) + 1,
								})
							end
						end
					end
					pending = pending - 1
					if pending == 0 then
						cb(#out > 0 and out or nil)
					end
				end, bufnr)
			end)
		end
	end
	if pending == 0 then
		cb(nil)
	end
end

local function ts_items(query)
	local match = pulse.make_matcher(query or "", { ignore_case = true, plain = true })
	local out, cwd = {}, vim.fn.getcwd()
	local patterns = { "function", "method", "class", "interface", "enum", "struct", "type", "declaration" }

	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted then
			local f = vim.api.nvim_buf_get_name(b)
			if f ~= "" and f:sub(1, #cwd) == cwd then
				local ok, p = pcall(vim.treesitter.get_parser, b)
				if ok and p then
					local ok2, trees = pcall(function()
						return p:parse()
					end)
					local root = ok2 and trees and trees[1] and trees[1]:root()
					if root then
						local function walk(n)
							local nt = n:type() or ""
							for _, ptn in ipairs(patterns) do
								if nt:find(ptn) then
									local txt = vim.treesitter.get_node_text(n, b)
									local name = vim.trim(type(txt) == "table" and table.concat(txt, "") or txt):gsub("\n.*$", "")
									if name ~= "" and match(name) then
										local r, c = n:range()
										table.insert(out, {
											kind = "workspace_symbol",
											symbol = name,
											filename = f,
											depth = 1,
											symbol_kind_name = "Symbol",
											container = "",
											lnum = r + 1,
											col = c + 1,
										})
									end
									break
								end
							end
							for ch in n:iter_children() do
								walk(ch)
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

function M.init(ctx)
	return {
		current_bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf(),
		symbols = {},
		last_query = nil,
		request_id = 0,
		on_update = ctx and ctx.on_update,
		fetching = false,
	}
end

function M.items(state, query)
	local q = query or ""
	if state.last_query ~= q then
		state.last_query = q
		state.request_id = state.request_id + 1
		state.symbols = {}
		state.fetching = true
		local rid = state.request_id
		local bufnr = state.current_bufnr or vim.api.nvim_get_current_buf()

		lsp_fetch(bufnr, q, function(items)
			if rid == state.request_id and state.fetching then
				state.symbols = items or ts_items(q)
				state.fetching = false
				if state.on_update then
					vim.schedule(state.on_update)
				end
			end
		end)
	end

	local filtered = state.symbols
	if q ~= "" then
		local match = pulse.make_matcher(q, { ignore_case = true, plain = true })
		filtered = {}
		for _, item in ipairs(state.symbols) do
			local hay = table.concat({ item.symbol or "", item.symbol_kind_name or "", item.container or "", item.filename or "" }, " ")
			if match(hay) then
				table.insert(filtered, item)
			end
		end
	end

	local by_file, cwd, out = {}, vim.fn.getcwd(), {}
	for _, item in ipairs(filtered) do
		local f = item.filename or ""
		if not by_file[f] then
			by_file[f] = {}
		end
		table.insert(by_file[f], item)
	end

	local files = vim.tbl_keys(by_file)
	table.sort(files)
	for _, file in ipairs(files) do
		local items = by_file[file]
		local rel = file:sub(1, #cwd) == cwd and file:sub(#cwd + 2) or file
		table.insert(out, { kind = "header", label = rel, path = file })
		for _, item in ipairs(items) do
			table.insert(out, item)
		end
	end

	return out
end

function M.total_count(state)
	return #(state.symbols or {})
end

return M
