local Client = require("src.client")

local function trim(text)
	if type(text) ~= "string" then
		return nil
	end

	local out = text:match("^%s*(.-)%s*$")
	if out == "" then
		return nil
	end

	return out
end

local function toInteger(text, fallback)
	local n = tonumber(text)
	if not n then
		return fallback
	end

	return math.floor(n)
end

local function fail(message)
	io.stderr:write(message .. "\n")
	os.exit(1)
end

local function loadLocalConfig()
	local ok, mod = pcall(require, "scripts.stress.local_config")
	if not ok or type(mod) ~= "table" then
		return {}
	end

	return mod
end

local cfg = loadLocalConfig()

local token = trim(os.getenv("DISCORD_BOT_TOKEN")) or trim(cfg.DISCORD_BOT_TOKEN)
if not token then
	fail("Missing DISCORD_BOT_TOKEN.")
end

local intents = toInteger(os.getenv("DISCORD_INTENTS"), cfg.DISCORD_INTENTS or 513)
local cycles = toInteger(os.getenv("FORCE_RECONNECT_CYCLES"), cfg.FORCE_RECONNECT_CYCLES or 3)
local intervalMs = toInteger(os.getenv("FORCE_RECONNECT_INTERVAL_MS"), cfg.FORCE_RECONNECT_INTERVAL_MS or 5000)
local settleMs = toInteger(os.getenv("FORCE_RECONNECT_SETTLE_MS"), cfg.FORCE_RECONNECT_SETTLE_MS or 8000)

if cycles <= 0 then
	fail("FORCE_RECONNECT_CYCLES must be > 0.")
end

if intervalMs < 0 then
	fail("FORCE_RECONNECT_INTERVAL_MS must be >= 0.")
end

if settleMs < 0 then
	fail("FORCE_RECONNECT_SETTLE_MS must be >= 0.")
end

local client = Client.new({
	token = token,
	intents = intents,
	autoRuntime = true,
	autoLoop = true,
	logEnabled = true,
	logLevel = "info",
	logTag = "reconnect-test",
})

local gateway = client.gateway
if type(gateway) ~= "table" then
	fail("Gateway is missing.")
end

local reconnectAttempts = 0
local reconnectSuccess = 0
local socketCloses = 0
local forcedCloses = 0
local readySeen = 0
local started = false

gateway:on("reconnect_attempt", function(info)
	reconnectAttempts = reconnectAttempts + 1
	print(("[reconnect-test] reconnect attempt #%d: %s delay=%s canResume=%s staleClose=%s"):format(
		reconnectAttempts,
		tostring(info and info.reason),
		tostring(info and info.delay),
		tostring(info and info.canResume),
		tostring(info and info.lastClose and info.lastClose.stale)
	))
end)

gateway:on("reconnect_success", function(reason, info)
	reconnectSuccess = reconnectSuccess + 1
	print(("[reconnect-test] reconnect success #%d: %s attempt=%s"):format(
		reconnectSuccess,
		tostring(reason),
		tostring(info and info.attempt)
	))
end)

gateway:on("close", function(clean, code, reason, info)
	socketCloses = socketCloses + 1
	print(("[reconnect-test] socket close #%d clean=%s code=%s reason=%s source=%s stale=%s conn=%s"):format(
		socketCloses,
		tostring(clean),
		tostring(code),
		tostring(reason),
		tostring(info and info.source),
		tostring(info and info.stale),
		tostring(info and info.connectionId)
	))
end)

gateway:on("error", function(err)
	if type(err) == "table" then
		print(("[reconnect-test] gateway error: %s | %s"):format(tostring(err.code), tostring(err.message)))
		return
	end

	print(("[reconnect-test] gateway error: %s"):format(tostring(err)))
end)

client:on("READY", function()
	readySeen = readySeen + 1
	print(("[reconnect-test] READY #%d"):format(readySeen))

	if started then
		return
	end

	started = true
	local spawn = gateway.spawn
	local sleep = gateway.sleep
	if type(spawn) ~= "function" or type(sleep) ~= "function" then
		print("[reconnect-test] scheduler missing")
		client:shutdown("forced_reconnect_test_no_scheduler")
		return
	end

	print(("[reconnect-test] starting worker cycles=%d intervalMs=%d settleMs=%d"):format(cycles, intervalMs, settleMs))

	local okSpawn, spawnErr = pcall(spawn, function()
		local okWorker, workerErr = xpcall(function()
			local waitSeconds = intervalMs / 1000
			print(("[reconnect-test] worker online waitSeconds=%.3f"):format(waitSeconds))

			for i = 1, cycles do
				if waitSeconds > 0 then
					print(("[reconnect-test] waiting %.3fs before close %d/%d"):format(waitSeconds, i, cycles))
					sleep(waitSeconds)
				end

				local socket = gateway.socket
				local close = type(socket) == "table" and (socket.close or socket.Close)
				if type(close) ~= "function" then
					print(("[reconnect-test] skip force-close #%d: socket is missing"):format(i))
				else
					forcedCloses = forcedCloses + 1
					print(("[reconnect-test] forcing close %d/%d"):format(i, cycles))
					pcall(close, socket)
				end
			end

			if settleMs > 0 then
				local settleSeconds = settleMs / 1000
				print(("[reconnect-test] settling for %.3fs"):format(settleSeconds))
				sleep(settleSeconds)
			end

			print(("[reconnect-test] done. forced=%d closes=%d attempts=%d success=%d ready=%d"):format(
				forcedCloses,
				socketCloses,
				reconnectAttempts,
				reconnectSuccess,
				readySeen
			))

			client:shutdown("forced_reconnect_test_complete")
		end, debug.traceback)

		if not okWorker then
			print(("[reconnect-test] worker crashed: %s"):format(tostring(workerErr)))
			client:shutdown("forced_reconnect_test_worker_crash")
		end
	end)

	if not okSpawn then
		print(("[reconnect-test] spawn failed: %s"):format(tostring(spawnErr)))
		client:shutdown("forced_reconnect_test_spawn_failed")
	end
end)

local ok, err = client:runWithLoop()
if not ok and err then
	fail("Forced reconnect stress test failed: " .. tostring(err))
end
