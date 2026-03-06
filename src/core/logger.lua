local Class = require("src.core.class")
local Serialize = require("src.core.serialize")

local Logger = Class.extend()

local LEVEL_ORDER = {
	error = 1,
	warn = 2,
	info = 3,
	debug = 4,
}

local DEFAULT_LEVEL = "info"

local function normalizeLevel(level)
	if type(level) ~= "string" then
		return DEFAULT_LEVEL
	end

	level = level:lower()
	if LEVEL_ORDER[level] == nil then
		return DEFAULT_LEVEL
	end

	return level
end

local function toText(value)
	local kind = type(value)
	if kind == "string" then
		return value
	end

	if kind == "number" or kind == "boolean" or kind == "nil" then
		return tostring(value)
	end

	if kind == "table" then
		return Serialize.value(value)
	end

	return Serialize.value(value)
end

function Logger:init(opts)
	opts = opts or {}

	self.enabled = opts.enabled == true
	self.level = normalizeLevel(opts.level)
	self.tag = opts.tag or "cord"
	self.writer = opts.writer or print
end

function Logger:setEnabled(enabled)
	self.enabled = enabled == true
	return self.enabled
end

function Logger:setLevel(level)
	self.level = normalizeLevel(level)
	return self.level
end

function Logger:canLog(level)
	if not self.enabled then
		return false
	end

	level = normalizeLevel(level)
	return LEVEL_ORDER[level] <= LEVEL_ORDER[self.level]
end

function Logger:log(level, event, data)
	if not self:canLog(level) then
		return false
	end

	local parts = {
		("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "]"),
		("[" .. self.tag .. "]"),
		("[" .. normalizeLevel(level) .. "]"),
	}

	if type(event) == "string" and event ~= "" then
		parts[#parts + 1] = event
	end

	if data ~= nil then
		parts[#parts + 1] = toText(data)
	end

	self.writer(table.concat(parts, " "))
	return true
end

function Logger:error(event, data)
	return self:log("error", event, data)
end

function Logger:warn(event, data)
	return self:log("warn", event, data)
end

function Logger:info(event, data)
	return self:log("info", event, data)
end

function Logger:debug(event, data)
	return self:log("debug", event, data)
end

return Logger
