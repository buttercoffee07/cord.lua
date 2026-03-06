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

local token = trim(os.getenv("DISCORD_BOT_TOKEN"))
if not token then
	fail("Missing DISCORD_BOT_TOKEN.")
end

local channelId = trim(os.getenv("STRESS_CHANNEL_ID"))
if not channelId then
	fail("Missing STRESS_CHANNEL_ID.")
end

local intents = toInteger(os.getenv("DISCORD_INTENTS"), 33281)
local total = toInteger(os.getenv("STRESS_COUNT"), 25)
local intervalMs = toInteger(os.getenv("STRESS_INTERVAL_MS"), 150)
local prefix = trim(os.getenv("STRESS_PREFIX")) or "rapid-stress"

if total <= 0 then
	fail("STRESS_COUNT must be > 0.")
end

if intervalMs < 0 then
	fail("STRESS_INTERVAL_MS must be >= 0.")
end

local client = Client.new({
	token = token,
	intents = intents,
	autoRuntime = true,
	autoLoop = true,
	logEnabled = true,
	logLevel = "info",
	logTag = "rapid-test",
})

local success = 0
local failed = 0

client:on("READY", function()
	local sleep = client.gateway and client.gateway.sleep
	local waitSeconds = intervalMs / 1000

	local spawn = client.gateway and client.gateway.spawn
	if type(spawn) ~= "function" then
		print("[rapid-test] scheduler missing")
		client:shutdown("rapid_message_test_no_scheduler")
		return
	end

	spawn(function()
		for i = 1, total do
			local content = ("%s #%d at %s"):format(prefix, i, os.date("%H:%M:%S"))
			local _, err = client.rest:request("POST", "/channels/" .. channelId .. "/messages", {
				content = content,
			})

			if err then
				failed = failed + 1
				print(("[rapid-test] failed #%d: %s"):format(i, tostring(err.message or err)))
			else
				success = success + 1
			end

			if waitSeconds > 0 and type(sleep) == "function" then
				sleep(waitSeconds)
			end
		end

		print(("[rapid-test] done. success=%d failed=%d"):format(success, failed))
		client:shutdown("rapid_message_test_complete")
	end)
end)

local ok, err = client:runWithLoop()
if not ok and err then
	fail("Rapid message stress test failed: " .. tostring(err))
end
