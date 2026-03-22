local config = require("pulse.config")
local mode = require("pulse.mode")
local panel = require("pulse.panel")
local scope = require("pulse.scope")

local M = {}

function M.visible_surfaces(modules, current_scope)
	return panel.visible_panels(modules, panel.scope_type(current_scope))
end

local function default_surface_for_mode(panels, mode_name, initial_panel)
	local local_panels = {}
	for _, entry in ipairs(panels or {}) do
		if entry.navigator == mode_name then
			local_panels[#local_panels + 1] = entry
		end
	end
	return panel.default_surface(local_panels, initial_panel) or panel.default_surface(panels, initial_panel)
end

function M.prompt_has_prefix(prompt)
	return config.options._by_start and config.options._by_start[prompt:sub(1, 1)] ~= nil
end

function M.current_buffer_mode(prompt, current_scope, current_mode_name, registry)
	if current_scope ~= "buffer" or M.prompt_has_prefix(prompt) or not current_mode_name then
		return nil
	end
	local current_mod = registry[current_mode_name]
	if current_mod and panel.supports_scope(current_mod, "buffer") then
		return current_mode_name, current_mod
	end
end

function M.reconcile_scope(args)
	local prompt = args.prompt
	local mode_name = args.mode_name
	local mod = args.mod
	local current_scope = args.current_scope
	local state = args.state
	local input = args.input
	local modules = args.modules
	local source_bufnr = args.source_bufnr

	if not (state.scope and mod and not panel.supports_scope(mod, current_scope)) then
		return mode_name, mod, current_scope, false
	end
	if current_scope == "buffer" and not M.prompt_has_prefix(prompt) then
		local surfaces = M.visible_surfaces(modules, state.scope)
		local target = panel.default_surface(surfaces, nil)
		if target and input then
			panel.select(state.active_panels, target)
			local next_prompt = mode.switch_prompt(prompt, target.navigator)
			if next_prompt ~= prompt then
				input:set_value(next_prompt)
				return mode_name, mod, current_scope, true
			end
		end
	end
	if panel.is_buffer_only(mod) then
		state.scope = scope.from_buffer(source_bufnr)
	elseif panel.supports_scope(mod, "workspace") then
		state.scope = nil
	end
	return mode_name, mod, panel.scope_type(state.scope), false
end

function M.ensure_implicit_buffer_scope(state, mod, source_bufnr)
	if not state.scope and panel.is_buffer_only(mod) then
		state.scope = scope.from_buffer(source_bufnr)
	end
end

function M.resolve_surface(args)
	local prompt = args.prompt
	local mode_name = args.mode_name
	local mod = args.mod
	local initial_panel = args.initial_panel
	local state = args.state
	local input = args.input
	local modules = args.modules

	local current_panel = panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local surfaces = M.visible_surfaces(modules, state.scope)
	local active_surface = panel.find_surface(surfaces, mode_name, current_panel)
	if active_surface then
		return surfaces, active_surface, false
	end

	active_surface = default_surface_for_mode(surfaces, mode_name, initial_panel)
	panel.select(state.active_panels, active_surface)
	if active_surface and input then
		local next_prompt = mode.switch_prompt(prompt, active_surface.navigator)
		if next_prompt ~= prompt then
			input:set_value(next_prompt)
			return surfaces, active_surface, true
		end
	end
	return surfaces, active_surface, false
end

function M.apply_prompt_ui(input, current_mod, current_state, current_scope, query, active_surface, found, total)
	local navigator_mode = current_mod and current_mod.mode or {}
	local prompt_prefix = " " .. (navigator_mode.icon or "") .. " "
	local scoped = nil
	if current_mod and type(current_mod.input_scope) == "function" then
		scoped = current_mod.input_scope(current_state, current_scope)
	end
	local scope_text = scope.prompt_text(scoped)
	local prompt = prompt_prefix .. scope_text
	if scope_text ~= "" then
		prompt = prompt .. " "
	end
	input:set_prompt(prompt)
	input:set_addons({
		ghost = query == "" and active_surface and active_surface.label or nil,
		right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
		prompt_matches = scope.prompt_matches(scoped, #prompt_prefix),
	})
end

return M
