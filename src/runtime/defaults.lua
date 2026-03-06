local Defaults = {}

local function loadModule(name)
	local ok, mod = pcall(require, name)
	if not ok then
		return nil
	end

	return mod
end

local function makeRequestFn(https, ltn12)
	return function(req)
		local headers = {}
		if type(req.headers) == "table" then
			for name, value in pairs(req.headers) do
				headers[name] = value
			end
		end

		local body = req.body
		if type(body) == "string" then
			if headers["Content-Length"] == nil and headers["content-length"] == nil then
				headers["Content-Length"] = tostring(#body)
			end
		else
			body = nil
		end

		local bodyChunks = {}
		local ok, statusCode, headers, statusLine = https.request({
			url = req.url,
			method = req.method,
			headers = headers,
			source = body and ltn12.source.string(body) or nil,
			sink = ltn12.sink.table(bodyChunks),
			protocol = "tlsv1_2",
		})

		local status = tonumber(statusCode) or tonumber(ok) or 0
		local res = {
			status = status,
			statusCode = status,
			headers = headers or {},
			body = table.concat(bodyChunks),
			statusLine = statusLine,
		}

		if not ok then
			res.transportError = statusCode
		end

		return res
	end
end

local function makeWebSocketFactory(websocket, copas)
	return function(url)
		local listeners = {}
		local closed = false
		local ws = websocket.client.copas({ timeout = 10 })

		local sslParams = {
			mode = "client",
			protocol = "tlsv1_2",
			verify = "none",
			options = "all",
		}

		local ok, protocol, headers = ws:connect(url, nil, sslParams)
		if not ok then
			error("WebSocket connect failed: " .. tostring(protocol))
		end

		local function emit(event, ...)
			local list = listeners[event]
			if not list then
				return
			end

			for i = 1, #list do
				list[i](...)
			end
		end

		local socket = {}

		function socket:on(event, handler)
			if type(event) ~= "string" or event == "" then
				return false
			end

			if type(handler) ~= "function" then
				return false
			end

			local list = listeners[event]
			if not list then
				list = {}
				listeners[event] = list
			end

			list[#list + 1] = handler
			return true
		end

		function socket:send(payload)
			local sent, clean, code, reason = ws:send(payload)
			if not sent then
				return nil, reason or ("WebSocket send failed (close code " .. tostring(code) .. ").")
			end

			return true, clean
		end

		function socket:close()
			if closed then
				return true
			end

			closed = true
			local clean, code, reason = ws:close()
			emit("close", clean, code, reason)
			return clean, code, reason
		end

		copas.addthread(function()
			emit("open", {
				url = url,
				protocol = protocol,
				headers = headers,
			})

			while not closed do
				local message, opcode, clean, code, reason = ws:receive()
				if message then
					emit("message", message, opcode)
				else
					closed = true
					if reason and reason ~= "" then
						emit("error", {
							code = "websocket_receive_closed",
							message = reason,
							closeCode = code,
							clean = clean,
						})
					end
					emit("close", clean, code, reason)
				end
			end
		end)

		return socket
	end
end

function Defaults.load()
	local runtime = {}

	local copas = loadModule("copas")
	if copas then
		runtime.spawn = function(fn)
			return copas.addthread(fn)
		end

		runtime.sleep = function(seconds)
			return copas.sleep(seconds or 0)
		end

		runtime.loop = function(...)
			return copas.loop(...)
		end

		runtime.exit = function(...)
			return copas.exit(...)
		end
	end

	local https = loadModule("ssl.https")
	local ltn12 = loadModule("ltn12")
	if https and ltn12 then
		runtime.requestFn = makeRequestFn(https, ltn12)
	end

	local websocket = loadModule("websocket")
	if websocket and copas then
		runtime.wsFactory = makeWebSocketFactory(websocket, copas)
	end

	return runtime
end

return Defaults
