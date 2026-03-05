local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")
local RestClient = require("src.http.rest_client")
local Gateway = require("src.gateway.gateway")

local Client = Class.extend()

function Client:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0

	self.events = opts.events or EventEmitter.new()

	self.rest = opts.rest
		or RestClient.new({
			token = self.token,
			rateLimiter = opts.rateLimiter,
			baseUrl = opts.baseUrl,
			requestFn = opts.requestFn,
			json = opts.restJson or opts.json,
		})

	self.gateway = opts.gateway
		or Gateway.new({
			token = self.token,
			intents = self.intents,
			gatewayUrl = opts.gatewayUrl,
			wsFactory = opts.wsFactory,
			json = opts.gatewayJson or opts.json,
			spawn = opts.spawn,
			sleep = opts.sleep,
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

return Client
