# PR8058 device lane — bounded recovery checkpoint (2026-09-29, post-merge)

Merge (human, not by me): `0656875c5fbfbf1a7f339f4716a0b9059539d790` at 2026-09-29T13:16:34Z,
tested head `23106f0b8914b627823386939ea432aa553bb9d4`. This establishes **no device acceptance and
no cleanup by itself**.

## 1. Device cases actually completed (exact)
Current-head (`23106f0b`) run under the task cert: **none**. No page served over the task HTTPS
reached the phone as a successful load.
- `case1_root_discover_empty.png` / `_top.png` (07:40 local) — Safari **"Safari can't open the page
  because the server can't be found."** Not a case pass (DNS, no proxy).
- `settings_wifi_open.png`, `settings_wifi_open_top.png` (07:40), `settings_wifi_open2*` (07:42) —
  iOS **passcode prompt: "Enter iPhone Passcode for 'XCTest'" / "Enable UI Automation"**.
- `cleanup_now_ui.png` / `_top.png` (09:19 local) — current UI: Safari error page above.
Earlier tunnel-era captures (NOT current head, kept as history): `dev_ua2.png` (device identity,
`secure=true`), `dev_root_empty.png` (root landing), `dev_discover_empty.png` (`/discover`);
`dev_discover_empty2.png` = blank re-capture, unusable, no claim made; `control3_top.png` = LAN marker probe.
Served-head attribution for the task lane is **Mac-side only**: `lan_proxy.log` (OPEN lines for
`pr8058.test`, `seller.pr8058.test`, `store.example.test`), plus `/tmp/qa_root.html`,
`/tmp/qa_seller.html`, `/tmp/qa_custom.html`, `/tmp/qa_count.json` (`{"cart_items_count":0}`).

## 2. Task cert / proxy — before, current, cleanup
- **Before (11:35Z, saved):** `device_profiles_before.txt` — 3 provisioning profiles, **no
  configuration profile**; `device_details_before.txt`. The phone's Wi-Fi proxy setting was never
  recorded and never changed by this task.
- **Installed (11:39Z, receipts kept):** config profile `test.gumroad.pr8058` CMS-signed with the task
  leaf — `device_profile_install_signed_receipt.txt` (UUID 2879557E-90FA-40AD-9C4C-E45B3F6DBDC1) then
  `device_profile_install_ca_proxy_receipt.txt` (UUID 1533A865-1215-449F-8292-7230A7BEFA1D, Scope User;
  CA root + `com.apple.proxy.http.global` payload).
- **Global proxy never applied:** Safari kept doing DNS (error above) and `lan_proxy.log` contains zero
  device-sourced connections (all entries 127.0.0.1 = Mac side). The payload is supervised-only.
  ⇒ no Wi-Fi proxy change exists to restore.
- **Cleanup attempt (13:2xZ):** `xcrun devicectl device profile remove --device <udid> --type
  configuration test.gumroad.pr8058` → `ERROR: … was not found (CoreDeviceError 22701)`; repeated for
  the payload id `test.gumroad.pr8058.ca` → same. Receipts: `device_profile_remove_receipt.txt`
  (`/tmp/rm1.txt`), `/tmp/rm2.txt`, `/tmp/rm3.txt`. `devicectl device profile list --json-output`
  shows only `provisioningProfiles[0..2]` — **no configuration profile**. No unrelated profile was
  touched.
- **Residual uncertainty:** `ideviceprofile` is not installed, and the authoritative UI check
  (Settings → General → VPN & Device Management / Certificate Trust Settings) needs taps, which the
  device passcode blocks. So "no task CA present" rests on devicectl's lookup, not a UI read.
- **Task listeners:** `:3003`, `:3042`, `:8843` all **down**; no task-created tunnel process.
- **On-disk PKI kept (not installed anywhere else):** `~/.hermes/cache/scratch/pr8058-device/tls/`
  (`ca.key`/`leaf.key` mode 600 in a 700 dir, 7-day validity). Say the word and I shred them.
- Untracked QA helpers still in the worktree: `public/pr8058-ua.html`, `public/pr8058-ua.js`.

## 3. Precise unfinished case / blocker
First unfinished case: **root/Discover nonempty cart on the device** (then seller-subdomain and
custom-domain empty/nonempty/unreadable, plus the forced-failure case).
Blockers, in order:
1. **Device passcode gate for UI automation** — driving Settings → Wi-Fi → Configure Proxy requires
   XCTest UI Automation, which the device answers with "Enter iPhone Passcode for 'XCTest'".
   Not attempted, not guessable (screenshot `settings_wifi_open2_top.png`).
2. **Supervised-only global proxy** — `com.apple.proxy.http.global` installs but is ignored on this
   device, so the profile route cannot set the proxy.
3. Structural: `_gumroad_guid` is HttpOnly + server-minted, so a cart must be created by the device
   itself; LAN-only storefront hosts are unreachable to the phone without the proxy.
