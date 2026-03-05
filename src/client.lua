local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")
local RestClient = require("src.http.rest_client")
local Gateway = require("src.gateway.gateway")
local RuntimeDefaults = require("src.runtime.defaults")

local Client = Class.extend()

function Client:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0
	self.autoLoop = opts.autoLoop == true

	self.events = opts.events or EventEmitter.new()
	self.runtime = opts.runtime

	if not self.runtime and opts.autoRuntime ~= false then
		self.runtime = RuntimeDefaults.load()
	end

	local runtime = self.runtime or {}
	local requestFn = opts.requestFn or runtime.requestFn
	local wsFactory = opts.wsFactory or runtime.wsFactory
	local spawn = opts.spawn or runtime.spawn
	local sleep = opts.sleep or runtime.sleep

	self.loopFn = opts.loopFn or opts.loop or runtime.loop

	self.rest = opts.rest
		or RestClient.new({
			token = self.token,
			rateLimiter = opts.rateLimiter,
			baseUrl = opts.baseUrl,
			requestFn = requestFn,
			json = opts.restJson or opts.json,
		})

	self.gateway = opts.gateway
		or Gateway.new({
			token = self.token,
			intents = self.intents,
			gatewayUrl = opts.gatewayUrl,
			wsFactory = wsFactory,
			json = opts.gatewayJson or opts.json,
			spawn = spawn,
			sleep = sleep,
			identifyProperties = opts.identifyProperties,
			autoReconnect = opts.autoReconnect,
			reconnectBaseDelay = opts.reconnectBaseDelay,
			reconnectMaxDelay = opts.reconnectMaxDelay,
			random = opts.random,
		})

	self._gatewayDispatchHandler = function(eventName, data, payload)
		self:emit("dispatch", eventName, data, payload)
		self:emit(eventName, data, payload)
	end

	if type(self.gateway) == "table" and type(self.gateway.on) == "function" then
		self.gateway:on("dispatch", self._gatewayDispatchHandler)
	end
end

function Client:on(event, handler)
	return self.events:on(event, handler)
end

function Client:once(event, handler)
	return self.events:once(event, handler)
end

function Client:off(event, handler)
	return self.events:off(event, handler)
end

function Client:emit(event, ...)
	return self.events:emit(event, ...)
end

function Client:run(url)
	local gateway = self.gateway
	if type(gateway) ~= "table" or type(gateway.connect) ~= "function" then
		return nil, "Gateway is missing."
	end

	local ok, err = gateway:connect(url)
	if not ok then
		return nil, err
	end

	self:emit("run", url or gateway.gatewayUrl)
	return true
end

function Client:runWithLoop(url)
	local loopFn = self.loopFn
	if type(loopFn) ~= "function" then
		return nil, "Loop runner is missing."
	end

	local spawn = self.gateway and self.gateway.spawn
	if type(spawn) ~= "function" then
		return nil, "Scheduler is missing."
	end

	local started = false
	local runErr = nil

	spawn(function()
		local ok, err = self:run(url)
		if not ok then
			runErr = err
			return
		end

		started = true
	end)

	loopFn()

	if started then
		return true
	end

	return nil, runErr or "Loop stopped before client started."
end

return Client
