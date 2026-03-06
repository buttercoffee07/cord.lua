local Class = require("src.core.class")
local EventEmitter = require("src.core.event_emitter")
local Logger = require("src.core.logger")
local RestClient = require("src.http.rest_client")
local Gateway = require("src.gateway.gateway")
local RuntimeDefaults = require("src.runtime.defaults")
local Message = require("src.structures.message")

local Client = Class.extend()

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

local function parseDispatchData(client, eventName, data)
	if eventName == "MESSAGE_CREATE" and type(data) == "table" then
		return Message.new(client, data)
	end

	return data
end

local function callRest(self, name, ...)
	local rest = self.rest
	if type(rest) ~= "table" then
		return nil, "Rest client is missing."
	end

	local method = rest[name]
	if type(method) ~= "function" then
		return nil, "Rest method is missing: " .. tostring(name)
	end

	return method(rest, ...)
end

local function toMessage(self, data)
	if type(data) ~= "table" then
		return nil
	end

	return Message.new(self, data)
end

local function toMessageList(self, data)
	if type(data) ~= "table" then
		return {}
	end

	local out = {}
	for i = 1, #data do
		out[i] = Message.new(self, data[i])
	end

	return out
end

local function toReplyReference(channelId, messageId)
	if type(channelId) == "table" then
		local message = channelId
		return {
			message_id = message.id,
			channel_id = message.channelId,
			guild_id = message.guildId or (type(message.raw) == "table" and message.raw.guild_id) or nil,
		}
	end

	if messageId == nil then
		return nil
	end

	return {
		message_id = tostring(messageId),
		channel_id = tostring(channelId),
	}
end

local function toMessageBody(contentOrBody)
	if type(contentOrBody) == "table" then
		return copyTable(contentOrBody)
	end

	if contentOrBody == nil then
		return {}
	end

	return {
		content = tostring(contentOrBody),
	}
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

function Client:request(method, route, body)
	return callRest(self, "request", method, route, body)
end

function Client:get(route, query)
	return callRest(self, "get", route, query)
end

function Client:post(route, body, query)
	return callRest(self, "post", route, body, query)
end

function Client:put(route, body, query)
	return callRest(self, "put", route, body, query)
end

function Client:patch(route, body, query)
	return callRest(self, "patch", route, body, query)
end

function Client:delete(route, query)
	return callRest(self, "delete", route, query)
end

function Client:fetchSelf()
	return callRest(self, "getCurrentUser")
end

function Client:fetchUser(userId)
	return callRest(self, "getUser", userId)
end

function Client:createDM(recipientId)
	return callRest(self, "createDm", recipientId)
end

Client.createDm = Client.createDM

function Client:fetchChannel(channelId)
	return callRest(self, "getChannel", channelId)
end

function Client:fetchGuild(guildId)
	return callRest(self, "getGuild", guildId)
end

function Client:fetchGuildChannels(guildId)
	return callRest(self, "getGuildChannels", guildId)
end

function Client:fetchMessage(channelId, messageId)
	local res, err = callRest(self, "getChannelMessage", channelId, messageId)
	if not res then
		return nil, err
	end

	return toMessage(self, res.data), nil, res
end

function Client:fetchMessages(channelId, query)
	local res, err = callRest(self, "getChannelMessages", channelId, query)
	if not res then
		return nil, err
	end

	return toMessageList(self, res.data), nil, res
end

function Client:sendMessage(channelId, contentOrBody)
	local res, err = callRest(self, "createMessage", channelId, contentOrBody)
	if not res then
		return nil, err
	end

	return toMessage(self, res.data), nil, res
end

function Client:reply(channelId, messageId, contentOrBody)
	local reference = toReplyReference(channelId, messageId)
	if not reference or type(reference.message_id) ~= "string" or reference.message_id == "" then
		return nil, "Reply target is missing."
	end

	local targetChannelId = reference.channel_id
	if type(targetChannelId) ~= "string" or targetChannelId == "" then
		return nil, "Reply channel is missing."
	end

	local body = toMessageBody(contentOrBody)
	body.message_reference = body.message_reference or reference
	return self:sendMessage(targetChannelId, body)
end

function Client:replyToMessage(message, contentOrBody)
	return self:reply(message, nil, contentOrBody)
end

function Client:editMessage(channelId, messageId, contentOrBody)
	local res, err = callRest(self, "editMessage", channelId, messageId, contentOrBody)
	if not res then
		return nil, err
	end

	return toMessage(self, res.data), nil, res
end

function Client:deleteMessage(channelId, messageId)
	return callRest(self, "deleteMessage", channelId, messageId)
end

function Client:bulkDeleteMessages(channelId, messageIds)
	return callRest(self, "bulkDeleteMessages", channelId, messageIds)
end

function Client:triggerTyping(channelId)
	return callRest(self, "triggerTyping", channelId)
end

function Client:addReaction(channelId, messageId, emoji)
	return callRest(self, "addReaction", channelId, messageId, emoji)
end

function Client:removeOwnReaction(channelId, messageId, emoji)
	return callRest(self, "removeOwnReaction", channelId, messageId, emoji)
end

function Client:pinMessage(channelId, messageId)
	return callRest(self, "pinMessage", channelId, messageId)
end

function Client:unpinMessage(channelId, messageId)
	return callRest(self, "unpinMessage", channelId, messageId)
end

return Client
