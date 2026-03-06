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

local function sleepSeconds(seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return
	end

	local ok, socket = pcall(require, "socket")
	if ok and type(socket) == "table" and type(socket.sleep) == "function" then
		socket.sleep(seconds)
		return
	end

	local untilAt = os.clock() + seconds
	while os.clock() < untilAt do
	end
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

local channelId = trim(os.getenv("STRESS_CHANNEL_ID")) or trim(cfg.STRESS_CHANNEL_ID)
if not channelId then
	fail("Missing STRESS_CHANNEL_ID.")
end

local total = toInteger(os.getenv("STRESS_COUNT"), cfg.STRESS_COUNT or 25)
local intervalMs = toInteger(os.getenv("STRESS_INTERVAL_MS"), cfg.STRESS_INTERVAL_MS or 150)
local prefix = trim(os.getenv("STRESS_PREFIX")) or trim(cfg.STRESS_PREFIX) or "rapid-stress"

if total <= 0 then
	fail("STRESS_COUNT must be > 0.")
end

if intervalMs < 0 then
	fail("STRESS_INTERVAL_MS must be >= 0.")
end

local client = Client.new({
	token = token,
	intents = 0,
	autoRuntime = true,
	autoLoop = false,
	logEnabled = true,
	logLevel = "info",
	logTag = "rapid-test",
})

if not client.runtime or type(client.runtime.requestFn) ~= "function" then
	fail("HTTP runtime adapter is missing. Check lua_modules install.")
end

if type(client.sendMessage) ~= "function" then
	fail("Client message helper is missing.")
end

local success = 0
local failed = 0
local waitSeconds = intervalMs / 1000

print(("[rapid-test] starting burst count=%d intervalMs=%d channel=%s"):format(total, intervalMs, channelId))

for i = 1, total do
	local content = ("%s #%d at %s"):format(prefix, i, os.date("%H:%M:%S"))
	local _, err = client:sendMessage(channelId, content)

	if err then
		failed = failed + 1
		local status = err.status or (err.response and err.response.status)
		local apiCode = err.apiCode or (err.response and err.response.data and err.response.data.code)
		local detail = err.message or tostring(err)
		print(("[rapid-test] failed #%d: %s (status=%s apiCode=%s)"):format(
			i,
			tostring(detail),
			tostring(status),
			tostring(apiCode)
		))
		if err.response and err.response.body then
			print(("[rapid-test] response body: %s"):format(tostring(err.response.body)))
		end
	else
		success = success + 1
		print(("[rapid-test] sent #%d"):format(i))
	end

	if waitSeconds > 0 then
		sleepSeconds(waitSeconds)
	end
end

print(("[rapid-test] done. success=%d failed=%d"):format(success, failed))
client:destroy("rapid_message_test_complete")
