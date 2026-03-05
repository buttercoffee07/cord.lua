local Class = require("src.core.class")
local RateLimiter = require("src.http.rate_limiter")

local RestClient = Class.extend()

local DEFAULT_BASE_URL = "https://discord.com/api/v10"

local function makeError(code, message, extra)
	local err = {
		code = code,
		message = message,
	}

	if type(extra) == "table" then
		for key, value in pairs(extra) do
			err[key] = value
		end
	end

	return err
end

local function isSuccessStatus(status)
	return type(status) == "number" and status >= 200 and status < 300
end

local function formatStatusError(status)
	if type(status) == "number" then
		return ("Request failed with status %d."):format(status)
	end

	return "Request failed."
end

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
		return nil, makeError("invalid_method", "Method is required.")
	end

	if type(route) ~= "string" or route == "" then
		return nil, makeError("invalid_route", "Route is required.")
	end

	local requestFn = self.requestFn
	if type(requestFn) ~= "function" then
		return nil, makeError("missing_http_adapter", "HTTP adapter is missing.")
	end

	local methodUpper = method:upper()
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
				return nil, makeError("missing_json_encoder", "JSON encoder is missing.")
			end

			local okEncode, encoded = pcall(json.encode, body)
			if not okEncode or encoded == nil then
				return nil, makeError("encode_failed", "Failed to encode request body.", {
					cause = encoded,
				})
			end
			payload = encoded
		end
	end

	local req = {
		method = methodUpper,
		url = self.baseUrl .. route,
		headers = headers,
		body = payload,
	}

	local limiter = self.rateLimiter
	if type(limiter) ~= "table" or type(limiter.enqueue) ~= "function" then
		return nil, makeError("missing_rate_limiter", "Rate limiter is missing.")
	end

	local function sendRequest()
		local okCall, res = pcall(requestFn, req)
		if not okCall then
			return nil, makeError("http_adapter_crash", "HTTP adapter crashed.", {
				cause = res,
			})
		end

		if type(res) ~= "table" then
			return nil, makeError("invalid_response", "HTTP adapter returned invalid response.")
		end

		return res
	end

	local res, err = limiter:enqueue(route, sendRequest)
	if type(res) ~= "table" then
		if type(err) == "table" then
			return nil, err
		end

		return nil,
			makeError("request_failed", err or "Request failed.", {
				method = methodUpper,
				route = route,
			})
	end

	local rawBody = res.body
	if type(rawBody) == "string" and rawBody ~= "" and hasJsonContentType(res.headers) then
		local json = self.json
		if not json then
			return nil,
				makeError("missing_json_decoder", "JSON decoder is missing.", {
					method = methodUpper,
					route = route,
				})
		end

		local okDecode, decoded, decodeErr = pcall(json.decode, rawBody)
		if not okDecode or decoded == nil then
			return nil,
				makeError("decode_failed", decodeErr or "Failed to decode response body.", {
					method = methodUpper,
					route = route,
				})
		end
		res.data = decoded
	end

	local status = tonumber(res.status or res.statusCode)
	if status and not isSuccessStatus(status) then
		local msg = formatStatusError(status)
		local apiCode = nil

		if type(res.data) == "table" then
			if type(res.data.message) == "string" and res.data.message ~= "" then
				msg = res.data.message
			end
			apiCode = res.data.code
		end

		return nil,
			makeError("http_error", msg, {
				method = methodUpper,
				route = route,
				status = status,
				apiCode = apiCode,
				response = res,
			})
	end

	return res
end

return RestClient
