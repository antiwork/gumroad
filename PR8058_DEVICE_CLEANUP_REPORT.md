# PR8058 device lane — cleanup report (known / unknown), 2026-09-29

Scope of this report: resolve the install-vs-absence contradiction, verify listeners, record PKI
provenance, remove only task-owned material. No passcode bypass, no UI tests, no global proxy, no
reinstall, no GitHub writes.

## A. Contradiction resolved: transferred ≠ installed
`xcrun devicectl device profile list --help` states the verb "lists all profiles installed on the
device, **including both provisioning profiles (.mobileprovision) and configuration profiles
(.mobileconfig)**", with `--type provisioning|configuration`; the JSON result carries
`configurationProfiles`, `partialConfigurationProfiles`, `provisioningProfiles`. So the list verb *does*
enumerate configuration profiles.

Current device readout (device `00008150-000E3C2A0C85401C`, iOS 26.4.2):
- `--type configuration` → **"No configuration profiles found"**
- `--json-output` → `configurationProfiles = []`, `partialConfigurationProfiles = []`,
  `partialProvisioningProfiles = []`, outcome `success`
- `--type provisioning` → 3 (the pre-existing `gumclaw agent dev` profiles)

Raw install receipts end with: "Profile \"PR8058 temporary device QA (remove after run)\" **transferred
to device. Open Settings on the device and tap the profile to complete installation.**"
⇒ `devicectl ... install` returned rc 0 for a *transfer*; completion needs a user tap in Settings. No
completion happened, so nothing was installed and `profile remove` correctly reports
`was not found (CoreDeviceError 22701)`.

**Known:** no configuration profile is present on the device now (neither installed nor pending), per
the supported enumerating API. No task CA was ever trusted. Exit-0 install is **not** install proof,
and the provisioning-only listing is not removal proof — both were verified against the
configuration-profile fields instead.
**Unknown:** whether a profile was ever completed and later removed by someone else; there is no
completion record and no removal receipt on our side. `ideviceinfo -k ProfileList` returned empty, so
there is no independent second source.

### Exact task payload identifiers
- Outer configuration profile: `test.gumroad.pr8058` — "PR8058 temporary device QA (remove after run)"
- Payload `com.apple.security.root`: `test.gumroad.pr8058.ca`
- Payload `com.apple.proxy.http.global`: `test.gumroad.pr8058.proxy`
- Transfer UUIDs: `2879557E-90FA-40AD-9C4C-E45B3F6DBDC1` (CA-only), `1533A865-1215-449F-8292-7230A7BEFA1D`
  (CA + global proxy), both Scope `User`, created `2026-09-29 11:39:40Z` / `11:39:48Z`

### Raw receipt paths
- Install: `~/.hermes/cache/scratch/pr8058-device/device_profile_install_signed_receipt.txt`,
  `…/device_profile_install_ca_proxy_receipt.txt` (plus the earlier failed unsigned attempt in
  `…/device_profile_install_receipt.txt`)
- Removal attempts: `…/device_profile_remove_receipt.txt`, `/tmp/rm2.txt`, `/tmp/rm3.txt`
- Listing: `/tmp/pl.json` (JSON), commands above
- Before-state: `…/device_profiles_before.txt` (3 provisioning profiles, no configuration profile),
  `…/device_details_before.txt`

## B. Task PKI removed (fingerprints recorded first)
- CA: `CN=PR8058 Task CA, O=PR8058 device QA (temporary)` — SHA-256
  `6F:BD:06:C2:F9:C6:EA:F7:E1:51:36:27:08:F8:29:2C:31:EF:4C:97:77:0F:0D:C9:56:68:A4:92:E8:A0:01:A3`,
  valid 2026-09-29 11:35:57Z → 2026-10-06 11:35:57Z.
- Leaf: `CN=pr8058.test` — SANs `DNS:pr8058.test, DNS:*.pr8058.test, DNS:store.example.test,
  DNS:localhost, IP:127.0.0.1, IP:192.168.1.212` — SHA-256
  `EA:9A:3A:FD:F7:53:40:55:2B:68:33:06:B9:77:01:DC:95:89:BC:C1:6A:02:43:C0:22:4B:91:2C:62:D6:7D:DA`,
  same window.
- Removed: `…/pr8058-device/tls/` contents (both private keys, CA/leaf PEM+DER, CSR, confs) and the four
  `.mobileconfig` builds. Per-file sizes + SHA-256 kept in `…/pr8058-device/tls_material_manifest.txt`
  (written before deletion).
- **Not touched:** the broad mkcert CA — `~/Library/Application Support/mkcert/rootCA.pem` (mode 600,
  May 7, SHA-256 `3e218d65bfbe3a91bd024472f792974323c148c81c666a88663c2c6f3f10bff2`).
- Preserved: all logs, receipts, screenshots and reports in `~/.hermes/cache/scratch/pr8058-device/`.

## C. Listeners / processes
`:3003`, `:3042`, `:8843` all **down**; no `lan_proxy.py` / `boot_lane_https.sh` process. No
task-created tunnel.

## D. Manual step the iPhone asks for (verbatim, for the parent's card)
- Screen: passcode entry — **"Enter iPhone Passcode for "XCTest""** with subtitle
  **"Enable UI Automation"** (screenshot `…/settings_wifi_open2_top.png`).
- The person types the device passcode **on the iPhone**; that grants UI automation for the session.
- One entry is sufficient for the local Wi-Fi Settings automation *in that session*: the runner can then
  tap Settings → Wi-Fi → ⓘ → Configure Proxy → Manual → Server `192.168.1.212`, Port `8843` → Save, and
  drive Safari for the cases — provided the phone stays unlocked and USB-connected.
- Expect the prompt again for a restarted/new automation session, and expect a second passcode gate for
  a certificate **full-trust** toggle (Settings → General → About → Certificate Trust Settings). The
  profile-completion tap is itself manual: Settings → General → VPN & Device Management → tap
  "PR8058 temporary device QA" → Install.
