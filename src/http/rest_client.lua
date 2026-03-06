local Class = require("src.core.class")
local RateLimiter = require("src.http.rate_limiter")

local RestClient = Class.extend()

local DEFAULT_BASE_URL = "https://discord.com/api/v10"

local function copyTable(input)
	local out = {}
	if type(input) ~= "table" then
		return out
	end

	for key, value in pairs(input) do
		out[key] = value
	end

	return out
end

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

local function normalizeSnowflake(value, fieldName)
	fieldName = fieldName or "id"

	if value == nil then
		return nil, makeError("invalid_" .. fieldName, fieldName .. " is required.")
	end

	local text = tostring(value)
	if text == "" then
		return nil, makeError("invalid_" .. fieldName, fieldName .. " is required.")
	end

	return text
end

local function urlEncodeComponent(value)
	return (tostring(value):gsub("([^%w%-_%.~])", function(char)
		return ("%%%02X"):format(string.byte(char))
	end))
end

local function buildQuery(query)
	if type(query) ~= "table" then
		return nil
	end

	local keys = {}
	for key, value in pairs(query) do
		if value ~= nil then
			keys[#keys + 1] = key
		end
	end

	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for i = 1, #keys do
		local key = keys[i]
		local value = query[key]
		parts[#parts + 1] = urlEncodeComponent(key) .. "=" .. urlEncodeComponent(value)
	end

	if #parts == 0 then
		return nil
	end

	return table.concat(parts, "&")
end

local function appendQuery(route, query)
	local queryString = buildQuery(query)
	if not queryString or queryString == "" then
		return route
	end

	local separator = route:find("?", 1, true) and "&" or "?"
	return route .. separator .. queryString
end

local function toMessageReference(value)
	if value == nil then
		return nil
	end

	if type(value) ~= "table" then
		local messageId = tostring(value)
		if messageId == "" then
			return nil
		end

		return {
			message_id = messageId,
		}
	end

	local ref = {}
	local messageId = value.message_id or value.messageId or value.id
	if messageId ~= nil then
		messageId = tostring(messageId)
		if messageId ~= "" then
			ref.message_id = messageId
		end
	end

	local channelId = value.channel_id or value.channelId
	if channelId ~= nil then
		channelId = tostring(channelId)
		if channelId ~= "" then
			ref.channel_id = channelId
		end
	end

	local guildId = value.guild_id or value.guildId
	if guildId == nil and type(value.raw) == "table" then
		guildId = value.raw.guild_id
	end
	if guildId ~= nil then
		guildId = tostring(guildId)
		if guildId ~= "" then
			ref.guild_id = guildId
		end
	end

	if ref.message_id == nil then
		return nil
	end

	return ref
end

local function normalizeMessageBody(contentOrBody)
	local body
	if type(contentOrBody) == "table" then
		body = copyTable(contentOrBody)
	elseif contentOrBody == nil then
		body = {}
	else
		body = {
			content = tostring(contentOrBody),
		}
	end

	if body.message_reference == nil then
		local replyTarget = body.replyTo or body.reply_to or body.reference
		local ref = toMessageReference(replyTarget)
		if ref then
			body.message_reference = ref
		end
	end

	body.replyTo = nil
	body.reply_to = nil
	body.reference = nil

	return body
end

local function normalizeEmoji(emoji)
	if emoji == nil then
		return nil, makeError("invalid_emoji", "emoji is required.")
	end

	if type(emoji) == "table" then
		local id = emoji.id
		local name = emoji.name
		if id ~= nil and name ~= nil then
			return urlEncodeComponent(tostring(name) .. ":" .. tostring(id))
		end

		if name ~= nil then
			return urlEncodeComponent(tostring(name))
		end
	end

	local text = tostring(emoji)
	if text == "" then
		return nil, makeError("invalid_emoji", "emoji is required.")
	end

	return urlEncodeComponent(text)
end

function RestClient:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.selfbot = opts.selfbot == true
	self.rateLimiter = opts.rateLimiter
		or RateLimiter.new({
			sleep = opts.sleep,
			now = opts.now,
		})
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
		return nil, makeError("missing_http_adapter", "HTTP adapter is missing.", {
			method = method:upper(),
			route = route,
		})
	end

	local methodUpper = method:upper()
	local headers = {
		["Content-Type"] = "application/json",
		["User-Agent"] = "cord.lua (https://github.com/buttercoffee07/cord.lua, dev)",
	}

	if type(self.token) == "string" and self.token ~= "" then
		if self.selfbot then
			headers.Authorization = self.token
		else
			headers.Authorization = "Bot " .. self.token
		end
	end

	local payload = nil
	if body ~= nil then
		if type(body) == "string" then
			payload = body
		else
			local json = self.json
			if not json then
				return nil, makeError("missing_json_encoder", "JSON encoder is missing.", {
					method = methodUpper,
					route = route,
				})
			end

			local okEncode, encoded = pcall(json.encode, body)
			if not okEncode or encoded == nil then
				return nil, makeError("encode_failed", "Failed to encode request body.", {
					cause = encoded,
					method = methodUpper,
					route = route,
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
				method = methodUpper,
				route = route,
			})
		end

		if type(res) ~= "table" then
			return nil, makeError("invalid_response", "HTTP adapter returned invalid response.", {
				method = methodUpper,
				route = route,
			})
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

function RestClient:get(route, query)
	return self:request("GET", appendQuery(route, query))
end

function RestClient:post(route, body, query)
	return self:request("POST", appendQuery(route, query), body)
end

function RestClient:put(route, body, query)
	return self:request("PUT", appendQuery(route, query), body)
end

function RestClient:patch(route, body, query)
	return self:request("PATCH", appendQuery(route, query), body)
end

function RestClient:delete(route, query)
	return self:request("DELETE", appendQuery(route, query))
end

function RestClient:getCurrentUser()
	return self:get("/users/@me")
end

function RestClient:getUser(userId)
	local id, err = normalizeSnowflake(userId, "user_id")
	if not id then
		return nil, err
	end

	return self:get("/users/" .. id)
end

function RestClient:createDm(recipientId)
	local id, err = normalizeSnowflake(recipientId, "recipient_id")
	if not id then
		return nil, err
	end

	return self:post("/users/@me/channels", {
		recipient_id = id,
	})
end

RestClient.createDM = RestClient.createDm

function RestClient:getChannel(channelId)
	local id, err = normalizeSnowflake(channelId, "channel_id")
	if not id then
		return nil, err
	end

	return self:get("/channels/" .. id)
end

function RestClient:getChannelMessages(channelId, query)
	local id, err = normalizeSnowflake(channelId, "channel_id")
	if not id then
		return nil, err
	end

	return self:get("/channels/" .. id .. "/messages", query)
end

function RestClient:getChannelMessage(channelId, messageId)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	return self:get("/channels/" .. channel .. "/messages/" .. message)
end

function RestClient:createMessage(channelId, contentOrBody)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	return self:post("/channels/" .. channel .. "/messages", normalizeMessageBody(contentOrBody))
end

function RestClient:editMessage(channelId, messageId, contentOrBody)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	return self:patch("/channels/" .. channel .. "/messages/" .. message, normalizeMessageBody(contentOrBody))
end

function RestClient:deleteMessage(channelId, messageId)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	return self:delete("/channels/" .. channel .. "/messages/" .. message)
end

function RestClient:bulkDeleteMessages(channelId, messageIds)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	if type(messageIds) ~= "table" or #messageIds == 0 then
		return nil, makeError("invalid_message_ids", "messageIds must be a non-empty array.")
	end

	local messages = {}
	for i = 1, #messageIds do
		local messageId, messageErr = normalizeSnowflake(messageIds[i], "message_id")
		if not messageId then
			return nil, messageErr
		end

		messages[i] = messageId
	end

	return self:post("/channels/" .. channel .. "/messages/bulk-delete", {
		messages = messages,
	})
end

function RestClient:triggerTyping(channelId)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	return self:post("/channels/" .. channel .. "/typing", {})
end

function RestClient:addReaction(channelId, messageId, emoji)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	local encodedEmoji, emojiErr = normalizeEmoji(emoji)
	if not encodedEmoji then
		return nil, emojiErr
	end

	return self:put("/channels/" .. channel .. "/messages/" .. message .. "/reactions/" .. encodedEmoji .. "/@me")
end

function RestClient:removeOwnReaction(channelId, messageId, emoji)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	local encodedEmoji, emojiErr = normalizeEmoji(emoji)
	if not encodedEmoji then
		return nil, emojiErr
	end

	return self:delete("/channels/" .. channel .. "/messages/" .. message .. "/reactions/" .. encodedEmoji .. "/@me")
end

function RestClient:pinMessage(channelId, messageId)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	return self:put("/channels/" .. channel .. "/pins/" .. message)
end

function RestClient:unpinMessage(channelId, messageId)
	local channel, channelErr = normalizeSnowflake(channelId, "channel_id")
	if not channel then
		return nil, channelErr
	end

	local message, messageErr = normalizeSnowflake(messageId, "message_id")
	if not message then
		return nil, messageErr
	end

	return self:delete("/channels/" .. channel .. "/pins/" .. message)
end

function RestClient:getGuild(guildId)
	local id, err = normalizeSnowflake(guildId, "guild_id")
	if not id then
		return nil, err
	end

	return self:get("/guilds/" .. id)
end

function RestClient:getGuildChannels(guildId)
	local id, err = normalizeSnowflake(guildId, "guild_id")
	if not id then
		return nil, err
	end

	return self:get("/guilds/" .. id .. "/channels")
end

return RestClient
