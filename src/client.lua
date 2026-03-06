local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")
local Logger = require("src.core.logger")
local RestClient = require("src.http.rest_client")
local Gateway = require("src.gateway.gateway")
local RuntimeDefaults = require("src.runtime.defaults")
local Message = require("src.structures.message")

local Client = Class.extend()

local function parseDispatchData(client, eventName, data)
	if eventName == "MESSAGE_CREATE" and type(data) == "table" then
		return Message.new(client, data)
	end

	return data
end

function Client:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0
	self.autoLoop = opts.autoLoop == true

	self.events = opts.events or EventEmitter.new()
	self.logger = opts.logger
		or Logger.new({
			enabled = opts.logEnabled == true or opts.debug == true,
			level = opts.logLevel or "info",
			tag = opts.logTag or "cord",
			writer = opts.logWriter,
			json = opts.logJson or opts.json,
		})
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
	self.exitLoopFn = opts.exitLoopFn or opts.exitLoop or runtime.exit
	self._loopActive = false

	self.rest = opts.rest
		or RestClient.new({
			token = self.token,
			rateLimiter = opts.rateLimiter,
			baseUrl = opts.baseUrl,
			requestFn = requestFn,
			sleep = sleep,
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
		local parsed = parseDispatchData(self, eventName, data)
		self:emit("dispatch", eventName, parsed, payload)
		self:emit(eventName, parsed, payload)
	end

	if type(self.gateway) == "table" and type(self.gateway.on) == "function" then
		self.gateway:on("dispatch", self._gatewayDispatchHandler)

		if type(self.logger) == "table" and type(self.logger.warn) == "function" then
			self._gatewayErrorHandler = function(err)
				self.logger:warn("gateway.error", err)
			end
			self.gateway:on("error", self._gatewayErrorHandler)
		end
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
		if type(self.logger) == "table" and type(self.logger.error) == "function" then
			self.logger:error("client.run_failed", "Gateway is missing.")
		end
		return nil, "Gateway is missing."
	end

	local ok, err = gateway:connect(url)
	if not ok then
		if type(self.logger) == "table" and type(self.logger.error) == "function" then
			self.logger:error("client.run_failed", err)
		end
		return nil, err
	end

	local targetUrl = url or gateway.gatewayUrl
	if type(self.logger) == "table" and type(self.logger.info) == "function" then
		self.logger:info("client.run", {
			url = targetUrl,
		})
	end

	self:emit("run", targetUrl)
	return true
end

function Client:runWithLoop(url)
	local loopFn = self.loopFn
	if type(loopFn) ~= "function" then
		if type(self.logger) == "table" and type(self.logger.error) == "function" then
			self.logger:error("client.loop_missing", "Loop runner is missing.")
		end
		return nil, "Loop runner is missing."
	end

	local spawn = self.gateway and self.gateway.spawn
	if type(spawn) ~= "function" then
		if type(self.logger) == "table" and type(self.logger.error) == "function" then
			self.logger:error("client.scheduler_missing", "Scheduler is missing.")
		end
		return nil, "Scheduler is missing."
	end

	local started = false
	local runErr = nil
	local exitLoopFn = self.exitLoopFn

	self._loopActive = true

	spawn(function()
		local ok, err = self:run(url)
		if not ok then
			runErr = err
			if type(exitLoopFn) == "function" then
				pcall(exitLoopFn)
			end
			return
		end

		started = true
	end)

	local okLoop, loopErr = pcall(loopFn)
	self._loopActive = false

	if not okLoop then
		return nil, loopErr
	end

	if started then
		return true
	end

	return nil, runErr or "Loop stopped before client started."
end

function Client:shutdown(reason)
	local gateway = self.gateway
	if type(gateway) == "table" and type(gateway.off) == "function" then
		if self._gatewayDispatchHandler then
			gateway:off("dispatch", self._gatewayDispatchHandler)
		end

		if self._gatewayErrorHandler then
			gateway:off("error", self._gatewayErrorHandler)
		end
	end

	if type(gateway) == "table" and type(gateway.shutdown) == "function" then
		gateway:shutdown(reason or "client_shutdown")
	end

	local exitLoopFn = self.exitLoopFn
	if self._loopActive and type(exitLoopFn) == "function" then
		pcall(exitLoopFn)
	end

	if type(self.logger) == "table" and type(self.logger.info) == "function" then
		self.logger:info("client.shutdown", reason or "client_shutdown")
	end

	self:emit("shutdown", reason)
	return true
end

function Client:destroy(reason)
	self:shutdown(reason or "client_destroy")

	local events = self.events
	if type(events) == "table" and type(events.off) == "function" then
		events:off()
	end

	self._gatewayDispatchHandler = nil
	self._gatewayErrorHandler = nil
	return true
end

return Client
