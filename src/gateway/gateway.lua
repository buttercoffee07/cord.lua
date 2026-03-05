local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")

local Gateway = Class.extend()

local DEFAULT_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

local function loadJsonAdapter()
	local ok, cjson = pcall(require, "cjson")
	if ok and cjson and cjson.decode then
		return cjson
	end

	local okSafe, cjsonSafe = pcall(require, "cjson.safe")
	if okSafe and cjsonSafe and cjsonSafe.decode then
		return cjsonSafe
	end

	local okDk, dkjson = pcall(require, "dkjson")
	if okDk and dkjson and dkjson.decode then
		return {
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

local function bindSocketEvent(socket, name, handler)
	local on = socket.on
	if type(on) == "function" then
		on(socket, name, handler)
		return true
	end

	local add = socket.addEventListener
	if type(add) == "function" then
		add(socket, name, handler)
		return true
	end

	return false
end

function Gateway:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0
	self.sessionId = nil
	self.sequence = nil
	self.gatewayUrl = opts.gatewayUrl or DEFAULT_GATEWAY_URL
	self.wsFactory = opts.wsFactory
	self.json = opts.json or loadJsonAdapter()
	self.events = opts.events or EventEmitter.new()
	self.socket = nil
	self.connected = false
end

function Gateway:on(event, handler)
	return self.events:on(event, handler)
end

function Gateway:off(event, handler)
	return self.events:off(event, handler)
end

function Gateway:emit(event, ...)
	return self.events:emit(event, ...)
end

function Gateway:decodeMessage(raw)
	if type(raw) == "table" then
		return raw
	end

	if type(raw) ~= "string" or raw == "" then
		return nil, "Gateway message is empty."
	end

	local json = self.json
	if not json or type(json.decode) ~= "function" then
		return nil, "JSON decoder is missing."
	end

	local okDecode, payload, decodeErr = pcall(json.decode, raw)
	if not okDecode or payload == nil then
		return nil, decodeErr or "Failed to decode gateway message."
	end

	return payload
end

function Gateway:attachMessageListener(socket)
	local ok = bindSocketEvent(socket, "message", function(raw)
		local payload, err = self:decodeMessage(raw)
		if not payload then
			self:emit("error", {
				code = "gateway_decode_failed",
				message = err,
				raw = raw,
			})
			return
		end

		self:emit("message", payload, raw)
	end)

	if not ok then
		return nil, "Socket does not support message listeners."
	end

	return true
end

function Gateway:connect(url)
	local wsFactory = self.wsFactory
	if type(wsFactory) ~= "function" then
		return nil, "WebSocket factory is missing."
	end

	local targetUrl = url or self.gatewayUrl
	if type(targetUrl) ~= "string" or targetUrl == "" then
		return nil, "Gateway URL is required."
	end

	local okConnect, socket = pcall(wsFactory, targetUrl)
	if not okConnect or type(socket) ~= "table" then
		return nil, "Failed to connect to gateway."
	end

	local okMessage, messageErr = self:attachMessageListener(socket)
	if not okMessage then
		return nil, messageErr
	end

	bindSocketEvent(socket, "close", function(...)
		self.connected = false
		self:emit("close", ...)
	end)

	bindSocketEvent(socket, "error", function(...)
		self:emit("error", ...)
	end)

	bindSocketEvent(socket, "open", function(...)
		self.connected = true
		self:emit("open", ...)
	end)

	self.socket = socket
	self.connected = true
	self:emit("connect", targetUrl)
	return true
end

return Gateway
