local M = {}

local REGISTRY = {}

local function bucket(group, events)
	local entry = REGISTRY[group]
	if entry then
		return entry
	end

	entry = {
		states = setmetatable({}, { __mode = "k" }),
		group = vim.api.nvim_create_augroup(group, { clear = true }),
	}
	REGISTRY[group] = entry

	vim.api.nvim_create_autocmd(events, {
		group = entry.group,
		callback = function()
			for state, opts in pairs(entry.states) do
				if opts and (not opts.when or opts.when(state)) then
					if not state._sync_pending then
						state._sync_pending = true
						vim.schedule(function()
							state._sync_pending = false
							if opts.invalidate then
								opts.invalidate(state)
							end
							if opts.on_update then
								opts.on_update()
							end
						end)
					end
				end
			end
		end,
	})

	return entry
end

function M.register(state, opts)
	if not state or type(opts) ~= "table" then
		return
	end
	local group = assert(opts.group, "sync.register requires group")
	local events = assert(opts.events, "sync.register requires events")
	bucket(group, events).states[state] = opts
end

return M
