# Signal bot setup (one time, local, manual)

The "Send me a Signal message" button sends from a bot Signal account to one
fixed recipient. The Worker stores nothing: it needs five secrets, which you
create once with [signal-cli](https://github.com/AsamK/signal-cli) and then
put on the **production** Worker. Previews don't get them; their button says
"not configured".

Use signal-cli 0.14.9 (`nix shell nixpkgs#signal-cli`, pinned by this repo's
`flake.lock`); `scripts/export-creds` reads its data format.

## 1. Register the bot number

You need a phone number that can receive an SMS or a voice call and isn't
already on Signal (registering moves the number's Signal account to the bot).

```sh
nix shell nixpkgs#signal-cli nixpkgs#jq
# Solve the captcha at https://signalcaptchas.org/registration/generate.html,
# copy the "Open Signal" link (signalcaptcha://...).
signal-cli -a +15551234567 register --captcha 'signalcaptcha://...'
# Add --voice if the number can't receive SMS.
signal-cli -a +15551234567 verify 123456
```

Protect the number against re-registration by someone else:

```sh
signal-cli -a +15551234567 setPin 'a long PIN'
```

## 2. Find the recipient's ACI

From the phone that should receive the messages, send the bot any message,
then:

```sh
signal-cli -a +15551234567 -o json receive | jq -r '.envelope.sourceUuid'
```

That UUID is `TARGET_ACI`.

## 3. Export the secrets

```sh
scripts/export-creds +15551234567 <TARGET_ACI>
```

prints one `wrangler secret put` command each for `BOT_ACI`, `BOT_PASSWORD`,
`BOT_IDENTITY_KEY`, `BOT_REG_ID` and `TARGET_ACI`. Run them with credentials
for the production account (the Worker is `backstage`; set `WORKER` to target
another). Don't save them in the repository; for local testing, put
`KEY=value` lines in `.dev.vars` (gitignored), which `backstage dev` reads.

## 4. Stop using signal-cli for this account

From now on only the Worker uses the account. Running signal-cli on it again
would rotate its keys or registration and break the secrets. The bot can't
read replies.

## Notes

- Each press starts new sessions with every recipient device, so the
  recipient sees a fresh session each time; that's expected.
- Requests go through Signal's Fastly reflector, since Workers can't verify
  chat.signal.org's private-CA certificate (see `Signal.Api.server`).
- Deploys keep the Worker's secrets (`keep_bindings` in `tools/backstage`).
