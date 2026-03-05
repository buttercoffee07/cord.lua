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

	self.rest = opts.rest or RestClient.new({
		token = self.token,
		rateLimiter = opts.rateLimiter,
		baseUrl = opts.baseUrl,
		requestFn = opts.requestFn,
		json = opts.restJson or opts.json,
	})

	self.gateway = opts.gateway or Gateway.new({
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
end

return Client
