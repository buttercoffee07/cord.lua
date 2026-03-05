local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")

local Gateway = Class.extend()

local DEFAULT_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"
local DISPATCH_OPCODE = 0
local HEARTBEAT_OPCODE = 1
local IDENTIFY_OPCODE = 2
local RESUME_OPCODE = 6
local RECONNECT_OPCODE = 7
local INVALID_SESSION_OPCODE = 9
local HELLO_OPCODE = 10
local READY_EVENT = "READY"
local DEFAULT_RECONNECT_BASE = 1
local DEFAULT_RECONNECT_MAX = 30
local INVALID_SESSION_MIN_WAIT = 1
local INVALID_SESSION_MAX_WAIT = 5

local function loadJsonAdapter()
	local ok, cjson = pcall(require, "cjson")
	if ok and cjson and cjson.decode and cjson.encode then
		return cjson
	end

	local okSafe, cjsonSafe = pcall(require, "cjson.safe")
	if okSafe and cjsonSafe and cjsonSafe.decode and cjsonSafe.encode then
		return cjsonSafe
	end

	local okDk, dkjson = pcall(require, "dkjson")
	if okDk and dkjson and dkjson.decode and dkjson.encode then
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

local function readTaskTable()
	local taskLib = rawget(_G, "task")
	if type(taskLib) ~= "table" then
		return nil
	end

	return taskLib
end

local function defaultSpawn(fn)
	local taskLib = readTaskTable()
	if not taskLib or type(taskLib.spawn) ~= "function" then
		return nil
	end

	return taskLib.spawn(fn)
end

local function defaultSleep(seconds)
	local taskLib = readTaskTable()
	if not taskLib or type(taskLib.wait) ~= "function" then
		return nil
	end

	return taskLib.wait(seconds)
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
	self.spawn = opts.spawn or defaultSpawn
	self.sleep = opts.sleep or defaultSleep
	self.socket = nil
	self.connected = false
	self.heartbeatInterval = nil
	self.heartbeatRunning = false
	self.heartbeatThread = nil
	self.reconnectRunning = false
	self.reconnectAttempts = 0
	self.reconnectBaseDelay = opts.reconnectBaseDelay or DEFAULT_RECONNECT_BASE
	self.reconnectMaxDelay = opts.reconnectMaxDelay or DEFAULT_RECONNECT_MAX
	self.autoReconnect = opts.autoReconnect ~= false
	self.random = opts.random or math.random
	self.identifyProperties = opts.identifyProperties
		or {
			os = "linux",
			browser = "cord.lua",
			device = "cord.lua",
		}
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

function Gateway:send(payload)
	local socket = self.socket
	if type(socket) ~= "table" then
		return nil, "Socket is not connected."
	end

	local send = socket.send or socket.Send
	if type(send) ~= "function" then
		return nil, "Socket does not support send."
	end

	local wire = payload
	if type(payload) == "table" then
		local json = self.json
		if not json or type(json.encode) ~= "function" then
			return nil, "JSON encoder is missing."
		end

		local okEncode, encoded = pcall(json.encode, payload)
		if not okEncode or type(encoded) ~= "string" then
			return nil, "Failed to encode gateway payload."
		end
		wire = encoded
	end

	if type(wire) ~= "string" then
		return nil, "Gateway payload must be a string or table."
	end

	local okSend, sendErr = pcall(send, socket, wire)
	if not okSend then
		return nil, sendErr or "Failed to send gateway payload."
	end

	return true
end

function Gateway:sendHeartbeat()
	local ok, err = self:send({
		op = HEARTBEAT_OPCODE,
		d = self.sequence,
	})

	if not ok then
		return nil, err
	end

	self:emit("heartbeat", self.sequence)
	return true
end

function Gateway:sendIdentify()
	if type(self.token) ~= "string" or self.token == "" then
		return nil, "Gateway token is missing."
	end

	local payload = {
		op = IDENTIFY_OPCODE,
		d = {
			token = self.token,
			intents = self.intents,
			properties = self.identifyProperties,
		},
	}

	local ok, err = self:send(payload)
	if not ok then
		return nil, err
	end

	self:emit("identify", payload)
	return true
end

function Gateway:sendResume()
	if type(self.token) ~= "string" or self.token == "" then
		return nil, "Gateway token is missing."
	end

	if type(self.sessionId) ~= "string" or self.sessionId == "" then
		return nil, "Gateway session ID is missing."
	end

	if type(self.sequence) ~= "number" then
		return nil, "Gateway sequence is missing."
	end

	local payload = {
		op = RESUME_OPCODE,
		d = {
			token = self.token,
			session_id = self.sessionId,
			seq = self.sequence,
		},
	}

	local ok, err = self:send(payload)
	if not ok then
		return nil, err
	end

	self:emit("resume", payload)
	return true
end

function Gateway:resetReconnectBackoff()
	self.reconnectRunning = false
	self.reconnectAttempts = 0
	return true
end

function Gateway:getReconnectDelay()
	local attempt = self.reconnectAttempts
	if type(attempt) ~= "number" or attempt <= 0 then
		return 0
	end

	local base = tonumber(self.reconnectBaseDelay) or DEFAULT_RECONNECT_BASE
	local maxDelay = tonumber(self.reconnectMaxDelay) or DEFAULT_RECONNECT_MAX

	if base <= 0 then
		base = DEFAULT_RECONNECT_BASE
	end

	if maxDelay < base then
		maxDelay = base
	end

	local delay = base * (2 ^ (attempt - 1))
	if delay > maxDelay then
		delay = maxDelay
	end

	return delay
end

function Gateway:dropConnection(closeSocket)
	self:stopHeartbeatLoop()
	self.connected = false

	local socket = self.socket
	self.socket = nil
	if not closeSocket or type(socket) ~= "table" then
		return true
	end

	local close = socket.close or socket.Close
	if type(close) ~= "function" then
		return true
	end

	pcall(close, socket)
	return true
end

function Gateway:scheduleReconnect(opts)
	opts = opts or {}

	if self.reconnectRunning then
		return true
	end

	local canResume = opts.canResume ~= false
	if not canResume then
		self.sessionId = nil
		self.sequence = nil
	end

	local reason = opts.reason or "unknown"
	local minDelay = tonumber(opts.minDelay) or 0
	if minDelay < 0 then
		minDelay = 0
	end

	local spawn = self.spawn
	local sleep = self.sleep
	if type(spawn) ~= "function" or type(sleep) ~= "function" then
		return nil, "Reconnect scheduler is missing."
	end

	self.reconnectRunning = true
	self:dropConnection(true)

	local function attempt()
		if not self.reconnectRunning then
			return
		end

		self.reconnectAttempts = self.reconnectAttempts + 1
		local delay = self:getReconnectDelay()
		if delay < minDelay then
			delay = minDelay
		end

		self:emit("reconnect_attempt", {
			reason = reason,
			attempt = self.reconnectAttempts,
			delay = delay,
			canResume = canResume,
		})

		if delay > 0 then
			sleep(delay)
		end

		if not self.reconnectRunning then
			return
		end

		local okConnect, connectErr = self:connect(self.gatewayUrl)
		if okConnect then
			self:resetReconnectBackoff()
			self:emit("reconnect_success", reason)
			return
		end

		self:emit("error", {
			code = "gateway_reconnect_failed",
			message = connectErr,
			reason = reason,
			attempt = self.reconnectAttempts,
		})

		spawn(attempt)
	end

	spawn(attempt)
	return true
end

function Gateway:stopHeartbeatLoop()
	self.heartbeatRunning = false
	self.heartbeatThread = nil
	return true
end

function Gateway:startHeartbeatLoop()
	local interval = self.heartbeatInterval
	if type(interval) ~= "number" or interval <= 0 then
		return nil, "Heartbeat interval is missing."
	end

	if self.heartbeatRunning then
		return true
	end

	local spawn = self.spawn
	local sleep = self.sleep
	if type(spawn) ~= "function" or type(sleep) ~= "function" then
		return nil, "Heartbeat scheduler is missing."
	end

	if spawn == defaultSpawn then
		local taskLib = readTaskTable()
		if not taskLib or type(taskLib.spawn) ~= "function" then
			return nil, "Heartbeat scheduler is missing."
		end
	end

	if sleep == defaultSleep then
		local taskLib = readTaskTable()
		if not taskLib or type(taskLib.wait) ~= "function" then
			return nil, "Heartbeat scheduler is missing."
		end
	end

	local waitSeconds = interval / 1000
	self.heartbeatRunning = true

	local thread = coroutine.create(function()
		while self.connected and self.heartbeatRunning do
			local okBeat, beatErr = self:sendHeartbeat()
			if not okBeat then
				self:emit("error", {
					code = "gateway_heartbeat_send_failed",
					message = beatErr,
				})
			end

			coroutine.yield(waitSeconds)
		end
	end)

	self.heartbeatThread = thread

	local function step(delay)
		if not self.connected or not self.heartbeatRunning then
			return
		end

		if type(delay) == "number" and delay > 0 then
			sleep(delay)
		end

		if not self.connected or not self.heartbeatRunning then
			return
		end

		local okResume, nextDelay = coroutine.resume(thread)
		if not okResume then
			self:stopHeartbeatLoop()
			self:emit("error", {
				code = "gateway_heartbeat_loop_crash",
				message = nextDelay,
			})
			return
		end

		if coroutine.status(thread) == "dead" then
			self:stopHeartbeatLoop()
			return
		end

		spawn(function()
			step(nextDelay)
		end)
	end

	local okResume, firstDelay = coroutine.resume(thread)
	if not okResume then
		self:stopHeartbeatLoop()
		return nil, firstDelay
	end

	if coroutine.status(thread) ~= "dead" then
		spawn(function()
			step(firstDelay)
		end)
	end

	return true
end

function Gateway:handleHello(payload)
	local data = payload.d
	if type(data) ~= "table" then
		return nil, "HELLO payload is missing data."
	end

	local interval = tonumber(data.heartbeat_interval)
	if not interval or interval <= 0 then
		return nil, "HELLO payload has invalid heartbeat interval."
	end

	self.heartbeatInterval = interval
	self:emit("hello", interval, payload)

	local canResume = type(self.sessionId) == "string" and self.sessionId ~= "" and type(self.sequence) == "number"
	if canResume then
		local okResume, resumeErr = self:sendResume()
		if not okResume then
			self:emit("error", {
				code = "gateway_resume_failed",
				message = resumeErr,
			})
		end
	else
		local okIdentify, identifyErr = self:sendIdentify()
		if not okIdentify then
			self:emit("error", {
				code = "gateway_identify_failed",
				message = identifyErr,
			})
		end
	end

	local okStart, startErr = self:startHeartbeatLoop()
	if not okStart then
		self:emit("error", {
			code = "gateway_heartbeat_start_failed",
			message = startErr,
		})
	end

	return true
end

function Gateway:handleDispatch(payload)
	local eventName = payload.t
	if type(eventName) ~= "string" or eventName == "" then
		return nil, "Dispatch payload is missing event name."
	end

	if eventName == READY_EVENT then
		local data = payload.d
		if type(data) == "table" and type(data.session_id) == "string" and data.session_id ~= "" then
			self.sessionId = data.session_id
		end
	end

	self:emit("dispatch", eventName, payload.d, payload)
	self:emit(eventName, payload.d, payload)
	return true
end

function Gateway:handleReconnectRequest(payload)
	self:emit("reconnect_requested", payload)
	local ok, err = self:scheduleReconnect({
		reason = "opcode_7",
		canResume = true,
	})

	if not ok then
		return nil, err
	end

	return true
end

function Gateway:handleInvalidSession(payload)
	local canResume = payload.d == true
	self:emit("invalid_session", canResume, payload)

	local minDelay = 0
	if not canResume then
		local random = self.random
		if type(random) == "function" then
			minDelay = random(INVALID_SESSION_MIN_WAIT, INVALID_SESSION_MAX_WAIT)
		else
			minDelay = INVALID_SESSION_MIN_WAIT
		end
	end

	local ok, err = self:scheduleReconnect({
		reason = "opcode_9",
		canResume = canResume,
		minDelay = minDelay,
	})

	if not ok then
		return nil, err
	end

	return true
end

function Gateway:handlePayload(payload)
	if type(payload) ~= "table" then
		return
	end

	local seq = payload.s
	if type(seq) == "number" then
		self.sequence = seq
	end

	if payload.op == DISPATCH_OPCODE then
		local ok, err = self:handleDispatch(payload)
		if not ok then
			self:emit("error", {
				code = "gateway_dispatch_invalid",
				message = err,
				payload = payload,
			})
		end
		return
	end

	if payload.op == RECONNECT_OPCODE then
		local ok, err = self:handleReconnectRequest(payload)
		if not ok then
			self:emit("error", {
				code = "gateway_reconnect_invalid",
				message = err,
				payload = payload,
			})
		end
		return
	end

	if payload.op == INVALID_SESSION_OPCODE then
		local ok, err = self:handleInvalidSession(payload)
		if not ok then
			self:emit("error", {
				code = "gateway_invalid_session_failed",
				message = err,
				payload = payload,
			})
		end
		return
	end

	if payload.op == HELLO_OPCODE then
		local ok, err = self:handleHello(payload)
		if not ok then
			self:emit("error", {
				code = "gateway_hello_invalid",
				message = err,
				payload = payload,
			})
		end
	end
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
		self:handlePayload(payload)
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

	self.gatewayUrl = targetUrl

	local okConnect, socket = pcall(wsFactory, targetUrl)
	if not okConnect or type(socket) ~= "table" then
		return nil, "Failed to connect to gateway."
	end

	local okMessage, messageErr = self:attachMessageListener(socket)
	if not okMessage then
		return nil, messageErr
	end

	bindSocketEvent(socket, "close", function(...)
		self:stopHeartbeatLoop()
		self.connected = false
		self:emit("close", ...)

		if self.autoReconnect and not self.reconnectRunning then
			local okReconnect, reconnectErr = self:scheduleReconnect({
				reason = "socket_close",
				canResume = true,
			})

			if not okReconnect then
				self:emit("error", {
					code = "gateway_reconnect_schedule_failed",
					message = reconnectErr,
				})
			end
		end
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
