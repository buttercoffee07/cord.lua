local Class = require("src.core.class")

local EventEmitter = Class.extend()

local function getList(state, event)
	local list = state[event]
	if list then
		return list
	end

	list = {}
	state[event] = list
	return list
end

function EventEmitter:init()
	self._events = {}
end

function EventEmitter:on(event, handler)
	if type(event) ~= "string" or event == "" then
		return false, "Event name is required."
	end

	if type(handler) ~= "function" then
		return false, "Handler must be a function."
	end

	local list = getList(self._events, event)
	list[#list + 1] = { fn = handler }
	return true
end

function EventEmitter:once(event, handler)
	if type(event) ~= "string" or event == "" then
		return false, "Event name is required."
	end

	if type(handler) ~= "function" then
		return false, "Handler must be a function."
	end

	local onceHandler
	onceHandler = function(...)
		self:off(event, onceHandler)
		return handler(...)
	end

	local list = getList(self._events, event)
	list[#list + 1] = {
		fn = onceHandler,
		original = handler,
	}

	return true
end

function EventEmitter:off(event, handler)
	if event == nil then
		self._events = {}
		return true
	end

	local list = self._events[event]
	if not list then
		return true
	end

	if handler == nil then
		self._events[event] = nil
		return true
	end

	for i = #list, 1, -1 do
		local entry = list[i]
		if entry.fn == handler or entry.original == handler then
			table.remove(list, i)
		end
	end

	if #list == 0 then
		self._events[event] = nil
	end

	return true
end

function EventEmitter:emit(event, ...)
	local list = self._events[event]
	if not list or #list == 0 then
		return 0
	end

	local snapshot = {}

	for i = 1, #list do
		snapshot[i] = list[i]
	end

	for i = 1, #snapshot do
		snapshot[i].fn(...)
	end

	return #snapshot
end

return EventEmitter
