local Class = require("src.core.class")

local Gateway = Class.extend()

function Gateway:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.intents = opts.intents or 0
	self.sessionId = nil
	self.sequence = nil
end

return Gateway
