local Class = require("src.core.class")

local Client = Class.extend()

function Client:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0
end

return Client
