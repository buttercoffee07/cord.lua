local BaseStructure = require("src.structures.base_structure")

local Message = BaseStructure.extend()

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

return Message
