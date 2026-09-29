# PR8058 device checkpoint (recovery-only)

**Head served:** `23106f0b8914b627823386939ea432aa553bb9d4` (`git rev-parse HEAD` in worktree
`/Users/gumclaw/work/pr8058-device`); lane was `:3003` web + `:3042` vite with isolated DB
`gumroad_development_pr8058qa`. Lane is **down** after gateway restarts; nothing was restarted here.

**Device:** physical iPhone 17, UDID `00008150-000E3C2A0C85401C`; devicectl reports iOS 26.4.2;
device UA `... iPhone OS 18_7 like Mac OS X ... Version/26.4 Mobile/15E148 Safari/604.1` (Safari/WebKit 26.4).

**HTTPS trust:** unchanged. The pre-existing mccert dev CA (`~/Library/Application Support/mkcert/rootCA.pem`,
created 2026-05-07) is **not** trusted by the device — over IP the device shows "This Connection Is Not
Private" (`iphone_tls_ip.png`). No CA profile/`.mobileconfig` found in any prior evidence; therefore **no
previously-authorized certificate installation exists** and a trust root would be a human decision.

**Completed device cases / captures** (`~/.hermes/cache/scratch/pr8058-device/`):
1. device identity + `secure=true` on the served host — `dev_ua2.png`, `dev_ua2_top.png`
2. root landing page renders — `dev_root_empty.png`
3. `/discover` 200 + capture — `dev_discover_empty.png`, `dev_discover_empty_top.png`
   (blank re-capture `dev_discover_empty2.png` — NOT usable evidence, no claim made from it)
4. earlier LAN marker probe (device control) — `control3_top.png`
Parent's emulated/Playwright results stay separate from these.

**Exposure:** a task-created cloudflared quick tunnel briefly exposed the local lane publicly
(`nav-precipitation-kit-adapter.trycloudflare.com`, then `gave-enquiry-employed-explains.trycloudflare.com`).
Both processes are already gone (no `--url localhost:3003` cloudflared process; `:3003`/`:3042` free). Lane logs
show only 14 requests, all from my own client addresses (2 × 127.0.0.1, 12 × two IPv6 addresses); no third-party
clients. Content = local dev app pages on seeded demo data; no production/customer data, no credentials.
Public tunnels are outside the granted scope (local/LAN device testing) and will not be repeated.

**First missing step:** root/Discover **nonempty** cart on the device. Structurally blocked: `_gumroad_guid` is
HttpOnly and server-minted (`application_controller.rb:348`, no URL override), so the cart must be created by the
device itself via a storefront/checkout URL — and storefront hosts are unreachable LAN-only (device cannot resolve
nip.io/sslip.io: "server can't be found"; `/seller` on the root host 301s to `seller.<host>`).

**Hygiene:** no tracked source edits; two untracked QA helpers remain to be removed:
`public/pr8058-ua.html`, `public/pr8058-ua.js`.
