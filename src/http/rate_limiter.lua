local Class = require("src.core.class")

local RateLimiter = Class.extend()

local MAJOR_ROUTE_KEYS = {
	channels = true,
	guilds = true,
	webhooks = true,
}

local FALLBACK_RETRY_AFTER = 1
local DEFAULT_429_RETRIES = 5

local function isId(value)
	if type(value) ~= "string" then
		return false
	end

	return value:match("^%d+$") ~= nil
end

local function sleepSeconds(seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end

	local untilAt = os.clock() + seconds
	while os.clock() < untilAt do
	end
end

local function toNumber(value)
	if type(value) == "number" then
		if value >= 0 then
			return value
		end
		return nil
	end

	if type(value) == "string" then
		local num = tonumber(value)
		if num and num >= 0 then
			return num
		end
	end

	return nil
end

local function readRetryAfterHeader(headers)
	if type(headers) ~= "table" then
		return nil
	end

	local direct = headers["retry-after"] or headers["Retry-After"]
	if direct ~= nil then
		return direct
	end

	for name, value in pairs(headers) do
		if type(name) == "string" and name:lower() == "retry-after" then
			return value
		end
	end

	return nil
end

local function readRetryAfter(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local value = toNumber(payload.retry_after) or toNumber(payload.retryAfter)
	if value ~= nil then
		return value
	end

	value = toNumber(readRetryAfterHeader(payload.headers))
	if value ~= nil then
		return value
	end

	local body = payload.body
	if type(body) == "table" then
		value = toNumber(body.retry_after) or toNumber(body.retryAfter)
		if value ~= nil then
			return value
		end
	end

	return nil
end

local function is429(payload)
	if type(payload) ~= "table" then
		return false
	end

	local code = payload.status or payload.statusCode or payload.code
	return tonumber(code) == 429
end

local function isGlobal429(payload)
	if type(payload) ~= "table" then
		return false
	end

	if payload.global == true then
		return true
	end

	local body = payload.body
	if type(body) == "table" and body.global == true then
		return true
	end

	return false
end

local function get429Meta(packed)
	local total = rawget(packed, "n") or #packed
	for i = 2, total do
		local payload = packed[i]
		if type(payload) == "table" and type(payload.response) == "table" then
			payload = payload.response
		end

		if is429(payload) then
			return readRetryAfter(payload) or FALLBACK_RETRY_AFTER, isGlobal429(payload)
		end
	end

	return nil
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

function RateLimiter:init(opts)
	opts = opts or {}

	self.buckets = {}
	self.globalLock = false
	self.globalLockUntil = 0
	self.queue = {}
	self.max429Retries = opts.max429Retries or DEFAULT_429_RETRIES
	self.sleep = opts.sleep or sleepSeconds
	self.now = opts.now or os.clock
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

local function syncGlobalLock(state)
	if not state.globalLock then
		return false
	end

	local nowFn = state.now
	if type(nowFn) ~= "function" then
		return false
	end

	if nowFn() < state.globalLockUntil then
		return true
	end

	state.globalLock = false
	state.globalLockUntil = 0
	return false
end

local function lockGlobal(state, seconds)
	local nowFn = state.now
	if type(nowFn) ~= "function" then
		return
	end

	local untilAt = nowFn() + seconds
	if state.globalLockUntil < untilAt then
		state.globalLockUntil = untilAt
	end
	state.globalLock = true
end

local function waitIfGlobalLocked(state)
	if not syncGlobalLock(state) then
		return
	end

	local nowFn = state.now
	local waitFor = state.globalLockUntil - nowFn()
	if waitFor > 0 then
		local sleepFn = state.sleep
		if type(sleepFn) == "function" then
			pcall(sleepFn, waitFor)
		end
	end

	syncGlobalLock(state)
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
		retries429 = 0,
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
		waitIfGlobalLocked(self)

		local task = table.remove(queue, 1)

		local packed = table.pack(pcall(task.run))
		local ok = packed[1]
		local retryAfter, isGlobal = get429Meta(packed)
		if retryAfter ~= nil then
			task.retries429 = task.retries429 + 1
			if isGlobal then
				lockGlobal(self, retryAfter)
			end

			if task.retries429 <= self.max429Retries then
				table.insert(queue, 1, task)

				if not isGlobal then
					local sleepFn = self.sleep
					if type(sleepFn) == "function" then
						pcall(sleepFn, retryAfter)
					end
				end
			else
				task.done = true
				task.success = false
				task.error = "Rate limited too many times."
				removeGlobalTask(self.queue, task)
				processed = processed + 1
			end
		elseif ok then
			task.done = true
			task.success = true

			local total = rawget(packed, "n") or #packed
			local count = total - 1
			local results = {}
			for i = 1, count do
				results[i] = packed[i + 1]
			end

			task.results = results
			task.resultCount = count
			removeGlobalTask(self.queue, task)
			processed = processed + 1
		else
			task.done = true
			task.success = false
			task.error = packed[2]
			removeGlobalTask(self.queue, task)
			processed = processed + 1
		end
	end

	bucket.processing = false
	return true, processed
end

return RateLimiter
