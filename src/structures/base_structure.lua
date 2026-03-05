local Class = require("src.core.class")

local BaseStructure = Class.extend()

function BaseStructure:init(client, data)
	self.client = client
	self:patch(data)
end

function BaseStructure:patch(data)
	if type(data) ~= "table" then
		self.raw = nil
		return self
	end

	self.raw = data
	return self
end

return BaseStructure
