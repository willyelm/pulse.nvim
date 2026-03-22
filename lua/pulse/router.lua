local config = require("pulse.config")
local mode = require("pulse.mode")
local panel = require("pulse.panel")
local scope = require("pulse.scope")

local M = {}

local function default_panel_for_mode(panels, mode_name, initial_panel)
	local local_panels = {}
	for _, entry in ipairs(panels or {}) do
		if entry.navigator == mode_name then
			local_panels[#local_panels + 1] = entry
		end
	end
	return panel.default_panel(local_panels, initial_panel) or panel.default_panel(panels, initial_panel)
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

function M.reconcile_scope(prompt, mode_name, mod, current_scope, state, modules, source_bufnr)
	if not (state.scope and mod and not panel.supports_scope(mod, current_scope)) then
		return mode_name, mod, current_scope, false, nil
	end
	if current_scope == "buffer" and not M.prompt_has_prefix(prompt) then
		local panels = panel.visible_panels(modules, state.scope and panel.scope_type(state.scope) or "workspace")
		local target = panel.default_panel(panels, nil)
		if target then
			panel.select(state.active_panels, target)
			local next_prompt = mode.switch_prompt(prompt, target.navigator)
			if next_prompt ~= prompt then
				return mode_name, mod, current_scope, true, next_prompt
			end
		end
	end
	if panel.is_buffer_only(mod) then
		state.scope = scope.from_buffer(source_bufnr)
	elseif panel.supports_scope(mod, "workspace") then
		state.scope = nil
	end
	return mode_name, mod, panel.scope_type(state.scope), false, nil
end

function M.ensure_implicit_buffer_scope(state, mod, source_bufnr)
	if not state.scope and panel.is_buffer_only(mod) then
		state.scope = scope.from_buffer(source_bufnr)
	end
end

function M.resolve_panel(prompt, mode_name, mod, initial_panel, state, modules)
	local current_panel = panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local panels = panel.visible_panels(modules, state.scope and panel.scope_type(state.scope) or "workspace")
	local active_panel = panel.find_panel(panels, mode_name, current_panel)
	if active_panel then
		return panels, active_panel, false, nil
	end

	active_panel = default_panel_for_mode(panels, mode_name, initial_panel)
	panel.select(state.active_panels, active_panel)
	if active_panel then
		local next_prompt = mode.switch_prompt(prompt, active_panel.navigator)
		if next_prompt ~= prompt then
			return panels, active_panel, true, next_prompt
		end
	end
	return panels, active_panel, false, nil
end

function M.prompt_ui(current_mod, current_state, current_scope, query, active_panel, found, total)
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
	return {
		prompt = prompt,
		addons = {
			ghost = query == "" and active_panel and active_panel.label or nil,
			right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
			prompt_matches = scope.prompt_matches(scoped, #prompt_prefix),
		},
	}
end

return M
