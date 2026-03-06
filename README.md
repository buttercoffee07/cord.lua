# Cord

Cord is a metatable-based Discord library for Lua.

It is built around one goal: practical OOP that stays readable when the project gets real.

## Current status

Cord is in active dev. Core REST + Gateway flow is wired, stress scripts exist, and API ergonomics are in place.

## Philosophy

- Practical first. Ship features that solve real bot work.
- Explicit over clever. If a line is hard to read, it probably should not be there.
- Composition over inheritance. Small modules, clear jobs.
- No global shared state.
- Boring where it matters: networking, rate limits, reconnect, shutdown.

## Runtime requirements

Cord can auto-load runtime adapters through `src/runtime/defaults.lua`.

Expected Lua modules:

- `copas`
- `websocket` (Lua websocket lib with copas client support)
- `ssl.https`
- `ltn12`
- `cjson` or `dkjson`

If you do not want auto runtime loading, inject your own adapters in `Client.new({...})`.

## Minimal example

```lua
local Cord = require("src")

local client = Cord.new({
	token = os.getenv("DISCORD_BOT_TOKEN"),
	intents = 513, -- GUILDS + GUILD_MESSAGES
	autoRuntime = true,
	autoLoop = true,
})

client:on("MESSAGE_CREATE", function(message)
	if message.content == "!ping" then
		message:reply("pong")
	end
end)

local ok, err = client:runWithLoop()
if not ok then
	print("client failed:", err)
end
```

## Advanced example

```lua
local Cord = require("src")

local client = Cord.new({
	token = os.getenv("DISCORD_BOT_TOKEN"),
	intents = 33281, -- guilds + guild_messages + message_content
	autoRuntime = true,
	autoLoop = true,
	logEnabled = true,
	logLevel = "info",
	logTag = "example-bot",
})

client:on("READY", function(payload)
	local user = payload and payload.user or {}
	print(("online as %s (%s)"):format(tostring(user.username), tostring(user.id)))
end)

client:on("MESSAGE_CREATE", function(message)
	if message.author and message.author.bot then
		return
	end

	if message.content == "!ping" then
		message:reply("pong")
		return
	end

	if message.content == "!whoami" then
		local me, err = client:fetchSelf()
		if not me then
			message:reply("fetch failed: " .. tostring(err and err.message or err))
			return
		end

		message:reply("you are talking to " .. tostring(me.data and me.data.username))
		return
	end

	if message.content == "!pin" then
		message:pin()
	end
end)

client:on("gateway.error", function(err)
	print("gateway error:", err)
end)

local ok, err = client:runWithLoop()
if not ok then
	print("fatal:", err)
end
```

## API shape

You can stay high-level:

- `client:sendMessage(channelId, contentOrBody)`
- `client:reply(channelId, messageId, contentOrBody)`
- `client:editMessage(channelId, messageId, contentOrBody)`
- `client:deleteMessage(channelId, messageId)`
- `client:fetchMessage(channelId, messageId)`
- `client:fetchMessages(channelId, query)`
- `client:addReaction(channelId, messageId, emoji)`
- `client:removeOwnReaction(channelId, messageId, emoji)`
- `client:pinMessage(channelId, messageId)`
- `client:unpinMessage(channelId, messageId)`

Or drop lower when needed:

- `client:request(method, route, body)`
- `client:get(route, query)` / `post` / `put` / `patch` / `delete`

Message objects also carry helpers:

- `message:reply(contentOrBody)`
- `message:edit(contentOrBody)`
- `message:delete()`
- `message:react(emoji)` / `message:unreact(emoji)`
- `message:pin()` / `message:unpin()`
- `message:toReference()`

## Design tradeoffs

Cord intentionally picks clarity over fancy abstraction:

- Gateway and REST are separate modules, glued in `Client`.
- Structure parsing is shallow and explicit (`MESSAGE_CREATE -> Message`).
- Rate limiter is opinionated for Discord behavior, not generic HTTP.
- Error values are returned as plain Lua tables so they are easy to inspect and log.
- Runtime adapter loading is automatic by default, injectable when you need full control.

## Roadmap snapshot

From `todo.md`:

- Stage 1: Repository foundation (`DONE`)
- Stage 2: Rate limiting system (`DONE`)
- Stage 3: REST client core (`DONE`)
- Stage 4: Gateway core (`DONE`)
- Stage 5: Client layer (`DONE`)
- Stage 6: Structures (`DONE`)
- Stage 7: Internal hardening (`DONE`)
- Stage 8: Docs + release (`IN PROGRESS`)

Remaining high-level items:

- Full API docs file (`docs/API.md`)
- `v0.1.0` release tag

## Why this exists

A lot of Lua Discord libs either stop at wrappers or grow into hard-to-follow piles.

Cord is trying to stay in the useful middle:

- small enough to reason about
- real enough to run bots
- explicit enough that you can maintain it six months later
