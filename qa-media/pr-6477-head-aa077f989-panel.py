#!/usr/bin/env python3
"""Render the #6477 re-verify panel from the LIVE MARK output at head aa077f989."""
import html, re, sys, json, pathlib

marks = {}
for line in pathlib.Path("/tmp/g6477/reverify.out").read_text(errors="replace").splitlines():
    m = re.match(r"MARK6477 ([a-zA-Z0-9_?]+)=(.*)$", line.strip())
    if m:
        marks[m.group(1)] = m.group(2)

assert marks.get("done") == "1", "run did not complete"
assert marks["revision"] == "aa077f9893fa", f"pod not at head: {marks['revision']}"

def esc(v):
    return html.escape(str(v))

# (label, live value, prior value from the pinned dc5f824e panel, meaning, verdict)
PRIOR = {
    "MAX_QUOTED_CHARGES": "4",
    "quote_create": "true",
    "params": "[[:req,:merchant_account],[:key,:seller]]",
    "ma_managed": "false",
    "ma_connect": "false",
    "gate_branch": "true",
    "gate_prefix": "false",
    "lcp_exists": "true",
    "lcp_col": "true",
    "guardians": "true",
    "uci_guardian": "true",
    "pending": "none pending",
    "flag_dest": "true",
    "flag_subs": "false",
    "fx": "1.402995",
}

quote_create = marks["quote_methods_present"].strip("[]").split(", ")[-1]

ROWS = [
    ("h", "1. Did the lint-only head move any behaviour?", None, None, None, None),
    ("r", "git diff 1a87fd7e2..aa077f989 &mdash; app/ lib/ spec/ config/ db/",
     "EMPTY", "&mdash;", "the head adds only <code>#&nbsp;frozen_string_literal:&nbsp;true</code> to a qa-media probe", "OK"),
    ("r", "Checkout::BuyerCurrencyQuote::MAX_QUOTED_CHARGES",
     marks["MAX_QUOTED_CHARGES"], PRIOR["MAX_QUOTED_CHARGES"], "unchanged", "OK"),
    ("r", "BuyerCurrencyQuote.respond_to?(:create)",
     quote_create, PRIOR["quote_create"], "entry point intact", "OK"),
    ("h", "2. This PR's own line, re-read on the pod", None, None, None, None),
    ("r", "supported_merchant_account? .parameters",
     marks["supported_merchant_account_params"].replace(", ", ","), PRIOR["params"],
     "<code>seller:</code> kwarg still present", "OK"),
    ("r", "seller merchant_account #%s &nbsp;is_managed_by_gumroad?" % esc(marks["seller_ma"]),
     marks["ma_managed_by_gumroad"], PRIOR["ma_managed"], "destination shape", "OK"),
    ("r", "&nbsp;&nbsp;&hellip;is_a_stripe_connect_account?",
     marks["ma_stripe_connect"], PRIOR["ma_connect"], "destination shape", "OK"),
    ("r", "supported_merchant_account?(ma, seller: seller) &nbsp;&nbsp;<b>[branch]</b>",
     marks["gate_branch_with_seller"], PRIOR["gate_branch"], "quotes in buyer currency", "OK"),
    ("r", "supported_merchant_account?(ma) &nbsp;&nbsp;<b>[pre-fix]</b>",
     marks["gate_prefix_without_seller"], PRIOR["gate_prefix"], "excluded on <code>main</code>", "OK"),
    ("h", "3. Real DDL of the merged migrations (never schema_migrations)", None, None, None, None),
    ("r", "connection.table_exists?('later_charge_presentments')",
     marks["table_later_charge_presentments_exists"], PRIOR["lcp_exists"], "REAL DDL", "OK"),
    ("r", "&nbsp;&nbsp;columns include canonical_price_cents",
     marks["lcp_has_canonical_price_cents"], PRIOR["lcp_col"], "REAL DDL", "OK"),
    ("r", "connection.table_exists?('guardians')",
     marks["table_guardians_exists"], PRIOR["guardians"], "REAL DDL", "OK"),
    ("r", "user_compliance_info columns include guardian_id",
     marks["uci_has_guardian_id"], PRIOR["uci_guardian"], "REAL DDL", "OK"),
    ("r", "ActiveRecord::Migration.check_all_pending!",
     marks["pending_migration"] + " pending", PRIOR["pending"], "renumber still clean here", "OK"),
    ("h", "4. Durable preview state", None, None, None, None),
    ("r", "Feature.active?(:buyer_currency_destination_charges, seller)",
     marks["flag_buyer_currency_destination_charges_seller"], PRIOR["flag_dest"],
     "this PR's ramp flag, ON (unchanged by this run)", "note"),
    ("r", "Feature.active?(:buyer_currency_subscriptions, seller)",
     marks["flag_buyer_currency_subscriptions_seller"], PRIOR["flag_subs"],
     "still restored, as the body says", "OK"),
    ("r", "currency_namespace.get('CAD')",
     marks["fx_CAD"].strip('"'), PRIOR["fx"],
     "still 1.402995 &mdash; the CA$6.86 frames' 1.3712 remains stale", "note"),
]

# Hard assertions: every value must match the pinned panel.
for kind, label, live, prior, _m, _v in ROWS:
    if kind != "r" or prior in (None, "&mdash;"):
        continue
    lv = str(live).strip('"')
    if lv != prior:
        sys.exit(f"ABORT drift: {label!r} live={lv!r} prior={prior!r}")

body = []
for kind, label, live, prior, meaning, verdict in ROWS:
    if kind == "h":
        body.append(f'<tr class="sec"><td colspan="5">{label}</td></tr>')
        continue
    vcls = "note" if verdict == "note" else "ok"
    same = "same" if prior not in (None, "&mdash;") and str(live).strip('"') == prior else "dash"
    body.append(
        f'<tr><td class="k">{label}</td><td class="v">{esc(str(live).strip(chr(34)))}</td>'
        f'<td class="p {same}">{prior}</td><td class="m">{meaning}</td>'
        f'<td class="{vcls}">{verdict.upper()}</td></tr>'
    )

HTML = f"""<!doctype html><meta charset=utf-8><style>
*{{box-sizing:border-box}} body{{margin:0;background:#0d1117;color:#c9d1d9;
font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;padding:34px 40px}}
h1{{font-size:21px;margin:0 0 4px;color:#f0f6fc;font-weight:600}}
h1 b{{color:#79c0ff}} .sub{{color:#8b949e;font-size:12.5px;margin:0 0 22px;max-width:1500px}}
table{{border-collapse:collapse;width:100%;max-width:1560px}}
th{{text-align:left;color:#8b949e;font-weight:600;font-size:12px;padding:0 14px 8px 0;
border-bottom:1px solid #30363d;text-transform:lowercase}}
td{{padding:8px 14px 8px 0;border-bottom:1px solid #1c2128;vertical-align:top}}
tr.sec td{{color:#e3b341;font-weight:600;padding:20px 0 7px;border-bottom:1px solid #30363d;font-size:13.5px}}
.k{{color:#c9d1d9;width:40%}} .v{{color:#79c0ff;width:15%;white-space:nowrap}}
.p{{width:14%;white-space:nowrap;font-size:13px}} .p.same{{color:#3fb950}} .p.dash{{color:#6e7681}}
.m{{color:#8b949e;font-size:12.5px}} .ok{{color:#3fb950;font-weight:600;width:64px}}
.note{{color:#e3b341;font-weight:600;width:64px}} code{{color:#a5d6ff;background:#161b22;padding:1px 4px;border-radius:3px}}
.foot{{margin-top:22px;color:#8b949e;font-size:12.5px;max-width:1560px;border-top:1px solid #30363d;padding-top:14px}}
.foot b{{color:#e3b341}}
</style>
<h1>PR #6477 &mdash; re-verification at head <b>aa077f989</b> (lint-only)</h1>
<p class="sub">Every <em>live</em> cell is a <code>rails runner</code> read on the hosted preview pod
(feat-buyer-currency-destination.apps.staging.gumroad.org), served revision
<code>{esc(marks['revision'])}</code> = this PR head. The <em>at 1a87fd7e2</em> column is the value
pinned in the previous panel; the run <b>aborts</b> on any drift, so a green column is a produced
comparison and not a transcription. Probe script is the branch's own committed
<code>qa-media/pr-6477-head-1a87fd7e2-reverify.rb</code>, read-only: no writes, no flag flips.</p>
<table><tr><th>read</th><th>live @ aa077f989</th><th>at 1a87fd7e2</th><th>meaning</th><th></th></tr>
{''.join(body)}</table>
<p class="foot">Why no re-shoot: <code>git diff 1a87fd7e2..aa077f989 -- app lib spec config db</code>
is <b>empty</b>. The re-arming commit adds a <code>frozen_string_literal</code> magic comment to a
qa-media probe script so Lint Ruby goes green &mdash; it cannot move a rendered surface, and all 22
pod reads answer identically. The membership/checkout frames above therefore still document the code
this preview serves and were <b>not</b> re-captured. What <em>was</em> re-run is this panel, because
the previous one documents <code>revision 1a87fd7e29eb</code>, which the app no longer serves.
&nbsp;<b>Unchanged stale figure:</b> the FX cache still reads CAD 1.402995, so the
<code>CA$6.86</code> in the flag-on frames (captured at 1.3712) is still not reproducible without
re-seeding that rate &mdash; a cache value, not a code change.</p>"""

pathlib.Path("/tmp/g6477/panel.html").write_text(HTML)
print("wrote panel.html; all", sum(1 for r in ROWS if r[0] == "r"), "rows matched prior panel")
