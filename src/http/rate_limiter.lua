local Class = require("src.core.class")

local RateLimiter = Class.extend()

function RateLimiter:init()
	self.buckets = {}
	self.globalLock = false
	self.queue = {}
end

return RateLimiter
