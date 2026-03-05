local Class = require("src.core.class")
local RateLimiter = require("src.http.rate_limiter")

local RestClient = Class.extend()

local DEFAULT_BASE_URL = "https://discord.com/api/v10"

local function readHeader(headers, wanted)
	if type(headers) ~= "table" then
		return nil
	end

	local direct = headers[wanted]
	if direct ~= nil then
		return direct
	end

	local lowerWanted = wanted:lower()
	for name, value in pairs(headers) do
		if type(name) == "string" and name:lower() == lowerWanted then
			return value
		end
	end

	return nil
end

local function hasJsonContentType(headers)
	local contentType = readHeader(headers, "Content-Type")
	if type(contentType) ~= "string" then
		return false
	end

	return contentType:lower():find("application/json", 1, true) ~= nil
end

local function loadJsonAdapter()
	local ok, cjson = pcall(require, "cjson")
	if ok and cjson and cjson.encode and cjson.decode then
		return cjson
	end

	local okSafe, cjsonSafe = pcall(require, "cjson.safe")
	if okSafe and cjsonSafe and cjsonSafe.encode and cjsonSafe.decode then
		return cjsonSafe
	end

	local okDk, dkjson = pcall(require, "dkjson")
	if okDk and dkjson and dkjson.encode and dkjson.decode then
		return {
			encode = dkjson.encode,
			decode = function(text)
				local value, _, err = dkjson.decode(text)
				if err then
					return nil, err
				end
				return value
			end,
		}
	end

	return nil
end

function RestClient:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.rateLimiter = opts.rateLimiter or RateLimiter.new()
	self.baseUrl = opts.baseUrl or DEFAULT_BASE_URL
	self.requestFn = opts.requestFn
	self.json = opts.json or loadJsonAdapter()
end

function RestClient:request(method, route, body)
	if type(method) ~= "string" or method == "" then
		return nil, "Method is required."
	end

	if type(route) ~= "string" or route == "" then
		return nil, "Route is required."
	end

	local requestFn = self.requestFn
	if type(requestFn) ~= "function" then
		return nil, "HTTP adapter is missing."
	end

	local headers = {
		["Content-Type"] = "application/json",
		["User-Agent"] = "cord.lua (https://github.com/buttercoffee07/cord.lua, dev)",
	}

	if type(self.token) == "string" and self.token ~= "" then
		headers.Authorization = "Bot " .. self.token
	end

	local payload = nil
	if body ~= nil then
		if type(body) == "string" then
			payload = body
		else
			local json = self.json
			if not json then
				return nil, "JSON encoder is missing."
			end

			local okEncode, encoded = pcall(json.encode, body)
			if not okEncode or encoded == nil then
				return nil, "Failed to encode request body."
			end
			payload = encoded
		end
	end

	local req = {
		method = method:upper(),
		url = self.baseUrl .. route,
		headers = headers,
		body = payload,
	}

	local limiter = self.rateLimiter
	if type(limiter) ~= "table" or type(limiter.enqueue) ~= "function" then
		return nil, "Rate limiter is missing."
	end

	local function sendRequest()
		local res = requestFn(req)
		if type(res) ~= "table" then
			return nil, "HTTP adapter returned invalid response."
		end

		return res
	end

	local res, err = limiter:enqueue(route, sendRequest)
	if type(res) ~= "table" then
		return nil, err or "Request failed."
	end

	local rawBody = res.body
	if type(rawBody) == "string" and rawBody ~= "" and hasJsonContentType(res.headers) then
		local json = self.json
		if not json then
			return nil, "JSON decoder is missing."
		end

		local okDecode, decoded, decodeErr = pcall(json.decode, rawBody)
		if not okDecode or decoded == nil then
			return nil, decodeErr or "Failed to decode response body."
		end
		res.data = decoded
	end

	return res
end

return RestClient
