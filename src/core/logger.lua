local Class = require("src.core.class")

local Logger = Class.extend()

local LEVEL_ORDER = {
	error = 1,
	warn = 2,
	info = 3,
	debug = 4,
}

local DEFAULT_LEVEL = "info"

local function loadJsonAdapter()
	local ok, cjson = pcall(require, "cjson")
	if ok and cjson and cjson.encode then
		return cjson
	end

	local okSafe, cjsonSafe = pcall(require, "cjson.safe")
	if okSafe and cjsonSafe and cjsonSafe.encode then
		return cjsonSafe
	end

	local okDk, dkjson = pcall(require, "dkjson")
	if okDk and dkjson and dkjson.encode then
		return dkjson
	end

	return nil
end

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

local function toText(json, value)
	local kind = type(value)
	if kind == "string" then
		return value
	end

	if kind == "number" or kind == "boolean" then
		return tostring(value)
	end

	if kind == "table" and json and type(json.encode) == "function" then
		local ok, encoded = pcall(json.encode, value)
		if ok and type(encoded) == "string" then
			return encoded
		end
	end

	return tostring(value)
end

function Logger:init(opts)
	opts = opts or {}

	self.enabled = opts.enabled == true
	self.level = normalizeLevel(opts.level)
	self.tag = opts.tag or "cord"
	self.writer = opts.writer or print
	self.json = opts.json or loadJsonAdapter()
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
		parts[#parts + 1] = toText(self.json, data)
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
