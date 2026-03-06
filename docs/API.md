# Cord API

This doc matches the current code in `src/`.

## Import

```lua
local Cord = require("src")
```

`Cord` exports:

- `Cord.new(opts)` -> `Client`
- `Cord.Client`
- `Cord.Message`
- `Cord.RestClient`
- `Cord.Gateway`
- `Cord.EventEmitter`
- `Cord.Logger`

## Return conventions

Cord mostly uses this shape:

- success: `value` (or `value, nil, extra`)
- failure: `nil, err`

`err` is often a table from `RestClient` with:

- `code`
- `message`
- optional: `status`, `apiCode`, `route`, `method`, `response`, `cause`

## Client

### Constructor

```lua
local client = Cord.new({
  token = "...",
  intents = 33281,
  autoRuntime = true,
  autoLoop = true,
})
```

Common options:

- `token` string
- `intents` number
- `selfbot` boolean (uses raw REST auth; gateway `intents` are omitted unless explicitly provided)
- `autoRuntime` boolean (default true)
- `runtime` table (manual adapters)
- `autoLoop` boolean
- `logEnabled`, `logLevel`, `logTag`
- adapter overrides: `requestFn`, `wsFactory`, `spawn`, `sleep`, `loopFn`, `exitLoopFn`
- gateway overrides: `gatewayUrl`, `autoReconnect`, `reconnectBaseDelay`, `reconnectMaxDelay`

When `selfbot = true`, Cord also caches `client.user` / `client.userId` from `READY` and `fetchSelf()`.

### Events

`Client` is an emitter:

- `client:on(event, fn)`
- `client:once(event, fn)`
- `client:off(event, fn)`
- `client:emit(event, ...)`

Main emitted events:

- `run` (`url`)
- `shutdown` (`reason`)
- `dispatch` (`eventName`, `data`, `payload`)
- gateway dispatch names directly (`READY`, `MESSAGE_CREATE`, etc.)

`MESSAGE_CREATE` data is parsed into a `Message` object.

### Lifecycle

- `client:run(url?)` -> `true` or `nil, err`
- `client:runWithLoop(url?)` -> `true` or `nil, err`
- `client:shutdown(reason?)` -> `true`
- `client:destroy(reason?)` -> `true`

### Raw REST passthrough

- `client:request(method, route, body?)`
- `client:get(route, query?)`
- `client:post(route, body?, query?)`
- `client:put(route, body?, query?)`
- `client:patch(route, body?, query?)`
- `client:delete(route, query?)`

These return `res` or `nil, err` where `res` looks like:

```lua
{
  status = 200,
  statusCode = 200,
  headers = {...},
  body = "...",
  data = {...} -- when response body is JSON
}
```

### High-level API

- `client:fetchSelf()`
- `client:fetchUser(userId)`
- `client:createDM(recipientId)` (`client:createDm` alias also exists)
- `client:fetchChannel(channelId)`
- `client:fetchGuild(guildId)`
- `client:fetchGuildChannels(guildId)`

Message routes:

- `client:fetchMessage(channelId, messageId)` -> `Message, nil, res`
- `client:fetchMessages(channelId, query?)` -> `{Message...}, nil, res`
- `client:sendMessage(channelId, contentOrBody)` -> `Message, nil, res`
- `client:reply(channelIdOrMessage, messageId?, contentOrBody)` -> `Message, nil, res`
- `client:replyToMessage(message, contentOrBody)` -> `Message, nil, res`
- `client:editMessage(channelId, messageId, contentOrBody)` -> `Message, nil, res`
- `client:deleteMessage(channelId, messageId)` -> `res`
- `client:bulkDeleteMessages(channelId, messageIds)` -> `res`
- `client:triggerTyping(channelId)` -> `res`
- `client:addReaction(channelId, messageId, emoji)` -> `res`
- `client:removeOwnReaction(channelId, messageId, emoji)` -> `res`
- `client:pinMessage(channelId, messageId)` -> `res`
- `client:unpinMessage(channelId, messageId)` -> `res`

## Message structure

`Message` is created from `MESSAGE_CREATE` dispatch data.

Main fields:

- `message.id` string?
- `message.content` string
- `message.author` table?
- `message.authorId` string?
- `message.channelId` string?
- `message.guildId` string?
- `message.isSelf` boolean
- `message.raw` table? (from `BaseStructure`)
- `message.client` `Client`

Methods:

- `message:toReference()` -> `{message_id, channel_id?, guild_id?}` or `nil`
- `message:reply(contentOrBody)` -> `Message, nil, res`
- `message:edit(contentOrBody)` -> `self, nil, res`
- `message:delete()` -> `res`
- `message:react(emoji)` -> `res`
- `message:unreact(emoji)` -> `res`
- `message:pin()` -> `res`
- `message:unpin()` -> `res`

## RestClient

`RestClient` powers `Client.rest`.

### Constructor

```lua
local rest = RestClient.new({
  token = "...",
  requestFn = myHttpAdapter,
  rateLimiter = myLimiter, -- optional
  baseUrl = "https://discord.com/api/v10",
  json = myJsonAdapter,
})
```

### Methods

Base methods:

- `request`
- `get` / `post` / `put` / `patch` / `delete`

Discord helpers:

- `getCurrentUser`
- `getUser`
- `createDm` (`createDM` alias)
- `getChannel`
- `getChannelMessages`
- `getChannelMessage`
- `createMessage`
- `editMessage`
- `deleteMessage`
- `bulkDeleteMessages`
- `triggerTyping`
- `addReaction`
- `removeOwnReaction`
- `pinMessage`
- `unpinMessage`
- `getGuild`
- `getGuildChannels`

## Notes

- `query` tables are URL-encoded and appended to routes.
- `contentOrBody` accepts either a string (`content`) or a full Discord body table.
- Reply metadata can be passed as `message_reference`, or shorthand fields (`replyTo`, `reply_to`, `reference`) in `RestClient`.
