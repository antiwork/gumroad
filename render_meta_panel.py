import subprocess, html, sys

data = [
    ("/pricing", "Gumroad pricing: 10% flat fee", "No monthly fees, just a simple 10% cut per sale. Gumroad's pricing is transparent and creator-friendly.",
     "Gumroad pricing: 10% + 50¢ per sale, $0 monthly", "One simple fee: 10% + 50¢ per sale. No monthly fees, no setup costs, no surprises — and Gumroad handles sales tax worldwide as Merchant of Record, at no extra cost."),
    ("/features", "Gumroad features: Simple and powerful e-commerce tools", "Sell books, memberships, courses, and more with Gumroad's simple e-commerce tools. Everything you need to grow your audience.",
     "Gumroad features: Sell digital products, memberships & courses", "Everything you need to sell online: instant digital delivery, memberships, courses, pay-what-you-want pricing, affiliates, email marketing, and worldwide tax handling. Start selling in minutes — no monthly fees."),
]

def esc(s):
    return html.escape(s)

rows = ""
for path, old_t, old_d, new_t, new_d in data:
    rows += f"""
    <div class="block">
      <div class="path">{esc(path)}</div>
      <div class="cols">
        <div class="col old">
          <div class="hdr">BEFORE (main)</div>
          <div class="field"><span class="k">&lt;title&gt;</span>{esc(old_t)}</div>
          <div class="field"><span class="k">meta[description]</span>{esc(old_d)}</div>
        </div>
        <div class="col new">
          <div class="hdr">AFTER (preview, live-read via document.title / meta tags)</div>
          <div class="field"><span class="k">&lt;title&gt;</span>{esc(new_t)}</div>
          <div class="field"><span class="k">meta[description]</span>{esc(new_d)}</div>
        </div>
      </div>
    </div>
    """

page = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
body {{ background:#0d1117; color:#c9d1d9; font-family: 'SF Mono', Menlo, monospace; padding:40px; }}
h1 {{ color:#58a6ff; font-size:20px; }}
.sub {{ color:#8b949e; margin-bottom:24px; font-size:13px;}}
.block {{ margin-bottom:32px; border:1px solid #30363d; border-radius:8px; padding:16px; }}
.path {{ color:#f0883e; font-weight:bold; font-size:15px; margin-bottom:12px; }}
.cols {{ display:flex; gap:16px; }}
.col {{ flex:1; border-radius:6px; padding:12px; }}
.old {{ background:#2d1a1a; border:1px solid #f85149; }}
.new {{ background:#132d1a; border:1px solid #3fb950; }}
.hdr {{ font-size:11px; text-transform:uppercase; letter-spacing:0.05em; margin-bottom:10px; color:#8b949e; }}
.field {{ margin-bottom:8px; font-size:13px; line-height:1.5; word-wrap:break-word; }}
.k {{ display:block; color:#8b949e; font-size:11px; margin-bottom:2px; }}
</style></head>
<body>
<h1>PR #7090 — SEO meta tags on /pricing &amp; /features</h1>
<div class="sub">Comparing app/controllers/home_controller.rb meta values: origin/main vs seo-pricing-features-meta @ 20553014e6ee (live-read from preview via document.title / meta[name=description])</div>
{rows}
</body></html>"""

open("/tmp/meta_panel.html", "w").write(page)
print("written")
