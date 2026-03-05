local Class = require("src.core.class")
local RateLimiter = require("src.http.rate_limiter")

local RestClient = Class.extend()

function RestClient:init(opts)
	opts = opts or {}

	self.token = opts.token
	self.rateLimiter = opts.rateLimiter or RateLimiter.new()
end

return RestClient
