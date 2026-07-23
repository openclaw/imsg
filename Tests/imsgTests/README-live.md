# Live bridge smoke tests

These exercises run on a real SIP-disabled Mac with `Messages.app` signed in
and the helper dylib injected. They are gated by `IMSG_LIVE_BRIDGE=1` so they
never run in CI. Each step prints what should happen so you can eyeball the
result in `Messages.app` (the dylib has no way to fake-confirm a UI mutation).

## Prerequisites

```bash
# In Recovery mode
csrutil disable

# Back in normal boot:
make build && make build-dylib
imsg launch                 # kills + relaunches Messages with DYLD_INSERT
imsg status                 # expect: bridge version: v2 (v2 inbox active)
```

## Pick a target chat

```bash
imsg chats --limit 10 --json | jq -r '.[] | "\(.guid)\t\(.name // .identifier)"'
export CHAT='iMessage;-;+15551234567'    # paste guid from above
```

## 1. send-rich + effects

```bash
imsg send-rich --chat "$CHAT" --text "test from imsg v2"
imsg send-rich --chat "$CHAT" --text "BOOM" \
  --effect com.apple.MobileSMS.expressivesend.impact
imsg send-rich --chat "$CHAT" --text "📜 ---" \
  --effect com.apple.MobileSMS.expressivesend.invisibleink
```

Expect: each message shows in Messages.app immediately. The 2nd applies the
slam effect; the 3rd shows as invisible ink.

## 2. tapback round-trip

```bash
# Capture the messageGuid of an existing message you want to react to
imsg history --chat-id 1 --limit 1 --json | jq -r '.guid'
export MSG=<paste guid>
imsg tapback --chat "$CHAT" --message "$MSG" --kind love
imsg tapback --chat "$CHAT" --message "$MSG" --kind love --remove
```

Expect: 💖 appears, then disappears.

## 3. edit / unsend (macOS 13+ only)

```bash
imsg send-rich --chat "$CHAT" --text "rough draft"
# Capture the new guid:
imsg history --chat-id 1 --limit 1 --json | jq -r '.guid'
export MSG=<paste guid>
imsg edit --chat "$CHAT" --message "$MSG" --new-text "polished version"
imsg unsend --chat "$CHAT" --message "$MSG"
```

Expect: the message text changes, then a "You unsent a message" placeholder
appears. If `imsg status` shows `editMessageItemTranslation: ✗`,
`editMessageItem: ✗`, AND `editMessage: ✗`, the running macOS does not
expose a supported edit selector and these commands will return an error.

## 4. chat creation + member management

```bash
imsg chat-create --addresses '+15551111111,+15552222222' \
  --name 'imsg test' --text 'hello' --json
# Capture the new chatGuid from the JSON output:
export GROUP=<paste chatGuid>
imsg chat-add-member --chat "$GROUP" --address +15553333333
imsg chat-name --chat "$GROUP" --name 'imsg test renamed'
imsg chat-photo --chat "$GROUP" --file ~/Pictures/test.jpg
imsg chat-remove-member --chat "$GROUP" --address +15553333333
imsg chat-leave --chat "$GROUP"
```
`chat-create` is iMessage-only; use `imsg send --service sms` for SMS sends.

Expect: each step is visible in Messages.app within a second or two.

## 5. typing events streaming

```bash
imsg watch --bb-events --json &
# from another device or simulator, type into your conversation
# you should see started-typing / stopped-typing JSON objects emit
kill %1
```

## 6. introspection

```bash
imsg account
imsg whois --address +15551234567 --type phone
imsg nickname --address +15551234567
```

## Cleanup

```bash
killall Messages              # un-inject; next launch is normal
csrutil enable                # in Recovery, re-enable SIP when done
```
