# Container environment

## Secrets: Bitwarden / Vaultwarden

The Bitwarden CLI (`bw`) is installed. Use it to look up credentials instead of asking for them.

- If `BW_SERVER` is set, the CLI is already pointed at that (Vaultwarden) server.
- Log in non-interactively with an API key: `bw login --apikey` (reads `BW_CLIENTID` / `BW_CLIENTSECRET`).
- Unlock and keep the session: `export BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)"`.
- Check state with `bw status`; run `bw sync` before reading if items may have changed.
- Find items: `bw list items --search <term>`; fetch fields: `bw get password <id|name>`, `bw get username <id|name>`, `bw get totp <id|name>`, `bw get item <id> | jq ...`.
- Never print secret values to the user or write them into files that get committed.
