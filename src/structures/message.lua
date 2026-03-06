local BaseStructure = require("src.structures.base_structure")

local Message = BaseStructure.extend()

local function getClientMethod(self, name)
	local client = self.client
	if type(client) ~= "table" then
		return nil, nil, "Message client is missing."
	end

	local method = client[name]
	if type(method) ~= "function" then
		return nil, nil, "Message client is missing."
	end

	return method, client
end

local function getIds(self)
	local channelId = self.channelId
	if type(channelId) ~= "string" or channelId == "" then
		return nil, nil, "Message channel is missing."
	end

	local messageId = self.id
	if type(messageId) ~= "string" or messageId == "" then
		return nil, nil, "Message id is missing."
	end

	return channelId, messageId
end

function Message:patch(data)
	BaseStructure.patch(self, data)

	if type(data) ~= "table" then
		self.id = nil
		self.content = ""
		self.author = nil
		self.channelId = nil
		self.guildId = nil
		return self
	end

	self.id = data.id and tostring(data.id) or nil
	self.content = data.content or ""
	self.author = data.author
	self.channelId = data.channel_id and tostring(data.channel_id) or nil
	self.guildId = data.guild_id and tostring(data.guild_id) or nil
	return self
end

function Message:toReference()
	if type(self.id) ~= "string" or self.id == "" then
		return nil
	end

	local ref = {
		message_id = self.id,
	}

	if type(self.channelId) == "string" and self.channelId ~= "" then
		ref.channel_id = self.channelId
	end

	if type(self.guildId) == "string" and self.guildId ~= "" then
		ref.guild_id = self.guildId
	end

	return ref
end

function Message:reply(contentOrBody)
	local method, client, err = getClientMethod(self, "replyToMessage")
	if not method then
		return nil, err
	end

	return method(client, self, contentOrBody)
end

function Message:edit(contentOrBody)
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "editMessage")
	if not method then
		return nil, methodErr
	end

	local updated, err, res = method(client, channelId, messageId, contentOrBody)
	if not updated then
		return nil, err
	end

	if type(updated.raw) == "table" then
		self:patch(updated.raw)
	end

	return self, nil, res
end

function Message:delete()
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "deleteMessage")
	if not method then
		return nil, methodErr
	end

	return method(client, channelId, messageId)
end

function Message:react(emoji)
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "addReaction")
	if not method then
		return nil, methodErr
	end

	return method(client, channelId, messageId, emoji)
end

function Message:unreact(emoji)
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "removeOwnReaction")
	if not method then
		return nil, methodErr
	end

	return method(client, channelId, messageId, emoji)
end

function Message:pin()
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "pinMessage")
	if not method then
		return nil, methodErr
	end

	return method(client, channelId, messageId)
end

function Message:unpin()
	local channelId, messageId, idErr = getIds(self)
	if not channelId then
		return nil, idErr
	end

	local method, client, methodErr = getClientMethod(self, "unpinMessage")
	if not method then
		return nil, methodErr
	end

	return method(client, channelId, messageId)
end

return Message
