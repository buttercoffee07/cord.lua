local Class = require("src.core.class")

local RateLimiter = Class.extend()

local MAJOR_ROUTE_KEYS = {
	channels = true,
	guilds = true,
	webhooks = true,
}

local function isId(value)
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

		if isId(part) then
			local isMajorId = prev and MAJOR_ROUTE_KEYS[prev]
			local isWebhookToken = twoBack == "webhooks" and isId(prev)
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

local function removeGlobalTask(queue, task)
	for i = #queue, 1, -1 do
		if queue[i] == task then
			table.remove(queue, i)
			return
		end
	end
end

function RateLimiter:enqueue(route, request)
	if type(request) ~= "function" then
		return nil, "Request must be a function."
	end

	local bucket, err = self:getBucket(route)
	if not bucket then
		return nil, err
	end

	local task = {
		run = request,
		done = false,
		success = false,
		results = nil,
		resultCount = 0,
		error = nil,
	}

	local queue = bucket.queue
	queue[#queue + 1] = task
	self.queue[#self.queue + 1] = task

	if not bucket.processing then
		self:processQueue(bucket)
	end

	if not task.done then
		return nil, "Request queued."
	end

	if not task.success then
		return nil, task.error
	end

	return table.unpack(task.results, 1, task.resultCount)
end

function RateLimiter:processQueue(bucket)
	if type(bucket) ~= "table" then
		return nil, "Bucket is required."
	end

	local queue = bucket.queue
	if type(queue) ~= "table" then
		return nil, "Invalid bucket queue."
	end

	if bucket.processing then
		return false
	end

	bucket.processing = true
	local processed = 0

	while #queue > 0 do
		local task = table.remove(queue, 1)
		removeGlobalTask(self.queue, task)

		local packed = table.pack(pcall(task.run))
		local ok = packed[1]
		task.done = true
		task.success = ok

		if ok then
			local total = rawget(packed, "n") or #packed
			local count = total - 1
			local results = {}
			for i = 1, count do
				results[i] = packed[i + 1]
			end

			task.results = results
			task.resultCount = count
		else
			task.error = packed[2]
		end

		processed = processed + 1
	end

	bucket.processing = false
	return true, processed
end

return RateLimiter
