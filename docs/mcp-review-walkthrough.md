# MCP review recording script

Use this script to record a real Gumroad connector walkthrough in ChatGPT. Run it
again after changing authentication, tools, or their descriptions. Record actual
tool results; the expectations below are not evidence that a case passed.

## Before recording

- Use a dedicated, non-admin review account containing only synthetic products.
  Keep its password in the company password manager, never in this file, a
  prompt, terminal output, or the recording.
- Verify its identity and current product, sales, and payout state before the
  take. Do not record a creator's real sales, buyer emails, or payout details.
- Open a separate Chrome window, hide the conversation sidebar, close unrelated
  tabs, and frame only the walkthrough window. Disable microphone capture unless
  intentionally narrating. Keep login/password entry outside the recording.
- At [ChatGPT Plugins](https://chatgpt.com/plugins), use **Add → Create custom MCP
  server**, URL `https://gumroad.com/chatgpt/v1/mcp`, and OAuth. Use the isolated
  account when authorizing. Inspect the consent screen before accepting it.
  In advanced OAuth settings, choose DCR and keep only `view_profile`,
  `view_sales`, `edit_products`, and `view_payouts`; deselect `account` and
  `view_public`.
- Verify the discovered inventory: `get_account`, `list_products`, `get_product`,
  `create_draft_product`, `publish_product`, `unpublish_product`, `list_sales`,
  and `list_payouts`. Start a new conversation with this connector selected.
- Choose a unique run label, e.g. `Review Focus Timer 2026-10-06-01`. Reuse that
  exact name and the returned product ID throughout this take. Do not act on an
  unrelated existing product.

## Recording script

Capture with the OS screen recorder through Codex computer use. On macOS open
Screenshot with Command-Shift-5, choose **Record Selected Portion**, frame the
Chrome content, choose a local output directory, and start recording. Pause or
stop before password entry, security challenges, or unrelated account screens.
For each scene, keep the prompt, relevant tool invocation, and completed response
legible before advancing. Follow the live UI instead of reusing element numbers
from an earlier recording.

### Browser-only results video

When the OS recorder captures the wrong desktop/window, make a clearly labeled
walkthrough of the completed live results with `scripts/mcp-review-video.mjs`.
This captures actual browser pixels through Codex computer use. It is a sequence
of screenshots with chosen reading durations, not continuous execution footage.
Do not present it as evidence that the OAuth interaction or a tool approval was
recorded live. Keep the full recording workflow above for that requirement.

In the computer-use REPL, select and inspect the intended browser/app target,
then use absolute paths for the helper and output directory:

```js
var helper = await import("/path/to/gumroad/scripts/mcp-review-video.mjs");
var scenes = [];
scenes.push(await helper.captureScene(chrome, "/path/to/private-output", "account", 12));
// Navigate through the actual results with computer use; inspect each scene.
scenes.push(await helper.captureScene(chrome, "/path/to/private-output", "draft", 15));
await helper.finishVideoManifest("/path/to/private-output", scenes);
```

Capture the tool inventory, connected account, sales/payout results, draft
confirmation and creation, publish result, final state, and unsupported-action
response. Use a new scene name each time; existing images are never overwritten.
Check every image before encoding. Encode with FFmpeg, omitting microphone audio
and labeling the result visibly:

```sh
ffmpeg -f concat -safe 0 -i /path/to/private-output/scenes.ffconcat \
  -vf "scale=1920:-2,drawbox=x=0:y=0:w=iw:h=86:color=black:t=fill,drawtext=text='Gumroad MCP - screenshot walkthrough of live results':fontsize=25:fontcolor=white:x=40:y=25" \
  -r 5 -c:v libx264 -crf 18 -pix_fmt yuv420p -an -movflags +faststart \
  /path/to/private-output/walkthrough.mp4
```

The manifest records capture times and display durations. Keep it with the
private source images; commit only the helper and this script.

## Scene prompts

| Scene | Prompt / on-screen action | Expected behavior and narration |
| --- | --- | --- |
| Connect | Show the connector name and discovered tools after OAuth returns. | “Gumroad connects with OAuth. This demonstration uses an isolated review account.” Do not claim public directory approval. |
| Account | “Show the connected Gumroad account and its currency.” | `get_account` identifies the intended account. Stop if it is the wrong creator. |
| Products | “What products do I have on Gumroad? Show their names, prices, and published states.” | `list_products` returns only this account's products. |
| Product detail | “Show the details of [ID returned above].” | `get_product` uses a real returned identifier. |
| Sales | “Show my 10 most recent successful sales.” | `list_sales`; an empty result is valid. “This synthetic account has no sales.” Do not call a limited result a complete date-range report. |
| Draft | “Create an unpublished draft named [run label] for USD $12 with the description ‘Synthetic connector review fixture. Not offered for sale.’ Confirm the name and price before creating it.” | Confirm the requested values in the live conversation. If the account is not USD, clarify before proceeding. `create_draft_product` uses `price_cents: 1200` for USD. |
| Verify draft | “Fetch the new draft by its returned ID and show its published state.” | `get_product` confirms `published: false`. Optionally show the same product in Gumroad's editor. |
| Publish boundary | “Try publishing only the new review draft. Ask me to confirm before doing so.” | Show the confirmation and actual tool result. With no payout method, publishing may be rejected. State the returned error; do not add financial details or claim a successful publish. Only record a success path with an account already approved and configured for that purpose. |
| Restore draft | “Unpublish only the review product we just created, then fetch it again.” | `unpublish_product`, then `get_product` confirms it is unpublished. If it never published, describe this as a no-op, not proof of a live-to-draft transition. |
| Payouts | “Show my recent payouts.” | `list_payouts`; an empty result is valid. Do not invent a current balance or next payout date from historical payout records. |
| Unsupported actions | In separate turns: “Delete my Gumroad account.” / “Show another creator's sales.” / “Email all my buyers a discount code.” | No account deletion, cross-account access, or outbound email tool is available. Record what the assistant actually does; no fabricated refusals. |
| End | Show the final unpublished state and summarize observed limitations. | “This recording demonstrates the flows shown. Empty data and a publishing restriction are reported as observed.” |

## Review and reuse

1. Stop the OS recording and save outside tracked source, for example
   `tmp/mcp-review/YYYY-MM-DD/walkthrough.mov`.
2. Watch the whole recording. Check text legibility, tool outcomes, account
   identity, sensitive data, and any accidental views of other apps. Remove
   credential segments entirely. Do not edit errors into apparent successes.
3. Record the date, endpoint, client, account's synthetic-data status, tool
   results, product IDs, and any failures in the private submission tracker.
   Keep passwords and OAuth tokens out of the tracker.
4. Attach the reviewed video using GitHub's media upload or another approved
   reviewer-accessible host. Do not commit video binaries. Verify playback and
   access using the reviewer's expected access level; a private-repo URL alone
   is not evidence that an external reviewer can view it.
5. Put the verified URL in the submission's walkthrough field (or
   `extensions.com.openai.review.demo_recording_url`). Keep reviewer credentials
   in the provider's dedicated credentials field. A recording is not a substitute
   for working demo access or a completed domain verification.

See [OpenAI's connection and test guide](https://developers.openai.com/plugins/deploy/connect-chatgpt)
and [submission guide](https://developers.openai.com/plugins/deploy/submission)
for the current portal requirements.
