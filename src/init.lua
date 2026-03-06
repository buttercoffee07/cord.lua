local Cord = {
	Client = require("src.client"),
	Message = require("src.structures.message"),
	RestClient = require("src.http.rest_client"),
	Gateway = require("src.gateway.gateway"),
	EventEmitter = require("src.core.event_emitter"),
	Logger = require("src.core.logger"),
}

function Cord.new(opts)
	return Cord.Client.new(opts)
end

return Cord