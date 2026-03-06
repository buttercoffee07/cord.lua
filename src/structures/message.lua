local BaseStructure = require("src.structures.base_structure")

local Message = BaseStructure.extend()

local function copyTable(input)
	local out = {}
	for key, value in pairs(input) do
		out[key] = value
	end
	return out
end

function Message:patch(data)
	BaseStructure.patch(self, data)

	if type(data) ~= "table" then
		self.id = nil
		self.content = ""
		self.author = nil
		self.channelId = nil
		return self
	end

	self.id = data.id and tostring(data.id) or nil
	self.content = data.content or ""
	self.author = data.author
	self.channelId = data.channel_id and tostring(data.channel_id) or nil
	return self
end

function Message:reply(contentOrBody)
	if type(self.channelId) ~= "string" or self.channelId == "" then
		return nil, "Message channel is missing."
	end

	local client = self.client
	if type(client) ~= "table" then
		return nil, "Message client is missing."
	end

	local rest = client.rest
	if type(rest) ~= "table" or type(rest.request) ~= "function" then
		return nil, "Rest client is missing."
	end

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

	if body.message_reference == nil and type(self.id) == "string" and self.id ~= "" then
		local ref = {
			message_id = self.id,
			channel_id = self.channelId,
		}

		local raw = self.raw
		if type(raw) == "table" and type(raw.guild_id) == "string" and raw.guild_id ~= "" then
			ref.guild_id = raw.guild_id
		end

		body.message_reference = ref
	end

	return rest:request("POST", "/channels/" .. self.channelId .. "/messages", body)
end

return Message
