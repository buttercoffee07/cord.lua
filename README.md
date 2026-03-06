# Cord

Cord is an object-oriented Discord library for Lua.

## Quick start

```lua
local Cord = require("src")

local client = Cord.new({
	token = os.getenv("DISCORD_BOT_TOKEN"),
	intents = 513,
	autoRuntime = true,
	autoLoop = true,
})

client:on("MESSAGE_CREATE", function(message)
	if message.content == "!ping" then
		message:reply("pong")
	end

	if message.content == "!wave" then
		client:sendMessage(message.channelId, "👋")
	end
end)

client:runWithLoop()
```

## Convenience helpers

Common bot tasks no longer need raw route strings:

- `client:sendMessage(channelId, contentOrBody)`
- `client:reply(channelId, messageId, contentOrBody)`
- `client:replyToMessage(message, contentOrBody)`
- `client:editMessage(channelId, messageId, contentOrBody)`
- `client:deleteMessage(channelId, messageId)`
- `client:fetchMessage(channelId, messageId)`
- `client:fetchMessages(channelId, query)`
- `client:triggerTyping(channelId)`
- `client:addReaction(channelId, messageId, emoji)`
- `client:removeOwnReaction(channelId, messageId, emoji)`
- `client:pinMessage(channelId, messageId)` / `client:unpinMessage(channelId, messageId)`
- `client:createDM(recipientId)`
- `client:fetchChannel(channelId)`
- `client:fetchGuild(guildId)` / `client:fetchGuildChannels(guildId)`
- `client:fetchSelf()` / `client:fetchUser(userId)`

Message instances now also expose ergonomic helpers:

- `message:reply(contentOrBody)`
- `message:edit(contentOrBody)`
- `message:delete()`
- `message:react(emoji)` / `message:unreact(emoji)`
- `message:pin()` / `message:unpin()`
- `message:toReference()`

## Vision

- Build a clean, metatable-based OOP Discord library.
- Keep the architecture minimal, explicit, and easy to reason about.
- Prioritize long-term stability over rushed features.
- Prove production-level systems design in the Lua ecosystem.

## Principles

- Composition over inheritance
- Isolated modules with clear boundaries
- No global state
- Small, stable iterative releases
