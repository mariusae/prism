# prism-relay-worker

The sync relay, hosted on Cloudflare Workers.

GitHub tells the relay of each push to a graph's repository. The relay
then tells every device that keeps that graph:

- **Macs** listen on a WebSocket (`prism_relay::Listener`).
- **iPhones** get a silent push through APNs, which wakes the app to
  sync, even in the background.

So another device's writing comes in within seconds, not when the app is
next opened. Devices prove they may hear about a repository with their
GitHub token; the relay checks it with GitHub and never stores it. It
stores only the iPhones' push tokens, per repository.

Every decision the relay makes is in [`prism-relay`](../prism-relay), as
pure functions tested natively. This crate is only the plumbing: routes,
one Durable Object per repository, and outbound `fetch`.

| Route | From | Does |
|---|---|---|
| `POST /github` | GitHub | A push webhook: tells the repository's devices. Answers `{"listening": n, "pushed": n, "forgotten": n}`. |
| `POST /devices` | an iPhone | Registers its push token: `{repository, token, environment, topic}`. |
| `DELETE /devices` | an iPhone | Forgets it: `{repository, token}`. |
| `GET /events?repository=owner/name` | a Mac | A WebSocket, sent `{"type":"push","after":"<commit>"}` on each push. `ping` is answered `pong`. |

`/devices` and `/events` take `Authorization: Bearer <GitHub token>`.

## Building

```sh
rustup target add wasm32-unknown-unknown
cargo build --target wasm32-unknown-unknown    # in this directory
```

This crate is a workspace of its own, because it builds only for wasm.

## Deploying

1. **Deploy.** You need [Node](https://nodejs.org) for `wrangler`.

   ```sh
   npx wrangler login
   npx wrangler deploy
   ```

   Note the host it prints, for example `prism-relay.<account>.workers.dev`.
   Ours is `prism-relay.prism-notes.workers.dev`, which is what the apps
   are built to use (`apps/weft/iOS/GitHub.xcconfig`).

2. **Webhook secret.** Make one with `openssl rand -hex 32`, then:

   ```sh
   npx wrangler secret put GITHUB_WEBHOOK_SECRET
   ```

3. **GitHub App** (github.com → Settings → Developer settings → GitHub
   Apps → the app). Under **Webhook**, tick *Active*, set the URL to
   `https://<host>/github` and the secret to the one from step 2. Under
   **Permissions & events → Subscribe to events**, tick **Push**.

4. **APNs key**, for iPhones (developer.apple.com → Certificates, IDs &
   Profiles → Keys → +). Enable *Apple Push Notifications service* and
   download the `.p8` file. Then:

   ```sh
   npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
   npx wrangler secret put APNS_KEY_ID
   npx wrangler secret put APNS_TEAM_ID
   ```

   List the apps' bundle identifiers in `APNS_TOPICS` in `wrangler.toml`.

5. **Check.** Write on one device. In the GitHub App's settings, under
   **Advanced → Recent Deliveries**, the push should show a `200` with
   `{"listening": …, "pushed": …}`.
