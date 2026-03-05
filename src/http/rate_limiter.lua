local Class = require("src.core.class")

local RateLimiter = Class.extend()

local MAJOR_KEYS = {
	channels = true,
	guilds = true,
	webhooks = true,
}

local function isSnowflake(value)
	if type(value) ~= "string" then
		return false
	end

	return value:match("^%d+$") ~= nil
end

local function cleanPath(route)
	local path = route:match("^[^?]+") or route
	path = path:gsub("/+", "/")

	if path == "" then
		return "/"
	end

	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end

	if #path > 1 and path:sub(-1) == "/" then
		path = path:sub(1, -2)
	end

	return path
end

function RateLimiter:init()
	self.buckets = {}
	self.globalLock = false
	self.queue = {}
end

function RateLimiter:normalizeRoute(route)
	if type(route) ~= "string" or route == "" then
		return nil, "Route is required."
	end

	local path = cleanPath(route)
	local parts = {}
	for part in path:gmatch("[^/]+") do
		parts[#parts + 1] = part
	end

	for i = 1, #parts do
		local part = parts[i]
		local prev = parts[i - 1]
		local twoBack = parts[i - 2]

		if isSnowflake(part) then
			local isMajorId = prev and MAJOR_KEYS[prev]
			local isWebhookToken = twoBack == "webhooks" and isSnowflake(prev)
			if not isMajorId and not isWebhookToken then
				parts[i] = ":id"
			end
		end
	end

	return "/" .. table.concat(parts, "/")
end

function RateLimiter:getBucket(route)
	local key, err = self:normalizeRoute(route)
	if not key then
		return nil, err
	end

	local buckets = self.buckets
	local bucket = buckets[key]
	if bucket then
		return bucket
	end

	bucket = {
		key = key,
		queue = {},
	}
	buckets[key] = bucket
	return bucket
end

return RateLimiter
