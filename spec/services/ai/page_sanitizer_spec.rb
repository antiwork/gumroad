# frozen_string_literal: true

require "spec_helper"

describe Ai::PageSanitizer do
  describe ".sanitize" do
    it "allows inline script tags" do
      sanitized = described_class.sanitize(%(<script>window.loaded = true;</script>))

      expect(sanitized).to include("<script>window.loaded = true;</script>")
    end

    it "allows event handler attributes" do
      sanitized = described_class.sanitize(%(<section onclick="openModal()" onscroll="trackScroll()">Open</section>))

      expect(sanitized).to include(%(onclick="openModal()"))
      expect(sanitized).to include(%(onscroll="trackScroll()"))
    end

    it "strips the literal on attribute while preserving real event handlers" do
      sanitized = described_class.sanitize(%(<button on="notAnEvent()" onclick="openCheckout()">Buy</button>))

      expect(sanitized).to include(%(onclick="openCheckout()"))
      expect(sanitized).not_to include(%(on="notAnEvent()"))
    end

    it "allows style blocks" do
      sanitized = described_class.sanitize(%(<style>.hero { color: red; }</style><section class="hero">Hi</section>))

      expect(sanitized).to include("<style>.hero { color: red; }</style>")
    end

    it "allows Tailwind CDN script tags" do
      sanitized = described_class.sanitize(%(<script src="https://cdn.tailwindcss.com"></script>))

      expect(sanitized).to include(%(<script src="https://cdn.tailwindcss.com"></script>))
    end

    it "allows approved script hosts case-insensitively" do
      sanitized = described_class.sanitize(%(<script src="https://CDN.tailwindcss.com"></script>))

      expect(sanitized).to include(%(<script src="https://CDN.tailwindcss.com"></script>))
    end

    it "strips script tags from unapproved hosts" do
      sanitized = described_class.sanitize(%(<script src="https://evil.com/x.js"></script><p>Safe</p>))

      expect(sanitized).not_to include("evil.com")
      expect(sanitized).to include("<p>Safe</p>")
    end

    it "strips javascript URLs from links" do
      sanitized = described_class.sanitize(%(<a href="javascript:alert(1)">Click</a>))

      expect(sanitized).to include("<a>Click</a>")
      expect(sanitized).not_to include("javascript:")
    end

    it "strips link targets that navigate the parent browsing context" do
      sanitized = described_class.sanitize(%(<a href="https://example.com" target="_top">Top</a><a href="https://example.com" target="_parent">Parent</a><a href="https://example.com" target="_blank">Blank</a>))

      expect(sanitized).not_to include(%(target="_top"))
      expect(sanitized).not_to include(%(target="_parent"))
      expect(sanitized).to include(%(target="_blank"))
    end

    it "strips deeply encoded javascript URLs from links" do
      sanitized = described_class.sanitize(%(<a href="java%25252573cript:alert(1)">Click</a>))

      expect(sanitized).to include("<a>Click</a>")
      expect(sanitized).not_to include("href=")
    end

    it "strips meta refresh tags" do
      sanitized = described_class.sanitize(%(<meta http-equiv="refresh" content="0;url=https://evil.com"><p>Stay</p>))

      expect(sanitized).not_to include("http-equiv")
      expect(sanitized).to include("<p>Stay</p>")
    end

    it "strips meta tags after unwrapping document wrappers" do
      sanitized = described_class.sanitize(%(<head><meta http-equiv="Content-Security-Policy" content="default-src *"><meta charset="utf-8"></head><p>Stay</p>))

      expect(sanitized).to include("<p>Stay</p>")
      expect(sanitized).not_to include("<meta")
      expect(sanitized).not_to include("Content-Security-Policy")
    end

    it "adds sandbox attributes to iframes without one" do
      sanitized = described_class.sanitize(%(<iframe src="https://example.com/embed"></iframe>))

      expect(sanitized).to include(%(sandbox="allow-scripts"))
    end

    it "overwrites permissive iframe sandbox attributes (seller can't widen the policy)" do
      sanitized = described_class.sanitize(%(<iframe src="https://example.com" sandbox="allow-scripts allow-same-origin allow-top-navigation"></iframe>))

      expect(sanitized).to include(%(sandbox="allow-scripts"))
      expect(sanitized).not_to include("allow-same-origin")
      expect(sanitized).not_to include("allow-top-navigation")
    end

    it "removes form action attributes" do
      sanitized = described_class.sanitize(%(<form action="https://evil.com"><button>Send</button></form>))

      expect(sanitized).to include("<form>")
      expect(sanitized).not_to include("action=")
    end

    it "removes formaction on buttons and inputs" do
      sanitized = described_class.sanitize(%(<form><button formaction="https://evil.com">x</button><input formaction="https://evil.com" type="submit"></form>))

      expect(sanitized).not_to include("formaction=")
    end

    it "preserves data image URLs" do
      sanitized = described_class.sanitize(%(<img src="data:image/png;base64,abcd" alt="Preview">))

      expect(sanitized).to include(%(src="data:image/png;base64,abcd"))
    end

    it "strips data HTML URLs from links" do
      sanitized = described_class.sanitize(%(<a href="data:text/html,<script>alert(1)</script>">Open</a>))

      expect(sanitized).to include("<a>Open</a>")
      expect(sanitized).not_to include("data:text/html")
    end

    it "strips any data: URL from navigable attributes, not just text/html" do
      sanitized = described_class.sanitize(%(<a href="data:application/xhtml+xml,<html><script>fetch('https://evil.com')</script></html>">Open</a>))

      expect(sanitized).to include("<a>Open</a>")
      expect(sanitized).not_to include("data:")
    end

    it "strips data: image URLs from navigable attributes (you don't navigate to an image)" do
      sanitized = described_class.sanitize(%(<a href="data:image/png;base64,abcd">Open</a>))

      expect(sanitized).not_to include("data:image/png")
    end

    it "strips executable data: document types from src" do
      sanitized = described_class.sanitize(%(<img src="data:text/html,<script>alert(1)</script>">))

      expect(sanitized).not_to include("data:text/html")
    end

    it "preserves data: SVG images in src (img context does not execute SVG script)" do
      sanitized = described_class.sanitize(%(<img src="data:image/svg+xml;base64,abcd">))

      expect(sanitized).to include("data:image/svg+xml")
    end

    it "strips data URLs from iframe src attributes" do
      sanitized = described_class.sanitize(%(<iframe src="data:image/svg+xml,<svg><script>alert(1)</script></svg>"></iframe>))

      expect(sanitized).to include(%(<iframe sandbox="allow-scripts"></iframe>))
      expect(sanitized).not_to include("data:image/svg+xml")
    end

    it "preserves SVG tags and attributes lowercased by the HTML parser" do
      sanitized = described_class.sanitize(<<~HTML)
        <svg viewBox="0 0 10 10" preserveAspectRatio="xMidYMid meet">
          <defs>
            <linearGradient id="gradient"><stop offset="0%" stop-color="#fff"></stop></linearGradient>
            <clipPath id="clip"><rect width="10" height="10"></rect></clipPath>
          </defs>
        </svg>
      HTML

      expect(sanitized).to include("<lineargradient")
      expect(sanitized).to include("<clippath")
      expect(sanitized).to include(%(viewbox="0 0 10 10"))
      expect(sanitized).to include(%(preserveaspectratio="xMidYMid meet"))
    end

    it "allows stylesheet link tags from approved font hosts" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter&display=swap">))

      expect(sanitized).to include("fonts.googleapis.com/css2?family=Inter")
      expect(sanitized).to include(%(rel="stylesheet"))
    end

    it "allows stylesheet link tags from fonts.bunny.net" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="https://fonts.bunny.net/css?family=inter">))

      expect(sanitized).to include("fonts.bunny.net")
    end

    it "strips stylesheet link tags from unapproved hosts" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="https://evil.com/styles.css"><p>Safe</p>))

      expect(sanitized).not_to include("evil.com")
      expect(sanitized).to include("<p>Safe</p>")
    end

    it "strips link tags with rel other than stylesheet" do
      sanitized = described_class.sanitize(%(<link rel="icon" href="https://fonts.googleapis.com/favicon.ico"><p>Safe</p>))

      expect(sanitized).not_to include(%(rel="icon"))
      expect(sanitized).to include("<p>Safe</p>")
    end

    it "strips link tags without rel" do
      sanitized = described_class.sanitize(%(<link href="https://fonts.googleapis.com/css2?family=Inter"><p>Safe</p>))

      expect(sanitized).not_to include("fonts.googleapis.com")
      expect(sanitized).to include("<p>Safe</p>")
    end

    it "strips http stylesheet link tags (https required)" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="http://fonts.googleapis.com/css?family=Inter">))

      expect(sanitized).not_to include("fonts.googleapis.com")
    end

    it "strips protocol-relative stylesheet hrefs (must be explicit https)" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="//fonts.googleapis.com/css?family=Inter">))

      expect(sanitized).not_to include("fonts.googleapis.com")
    end

    it "strips userinfo-spoofed stylesheet hrefs (host is what comes after @)" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet" href="https://fonts.googleapis.com@evil.com/styles.css">))

      expect(sanitized).not_to include("evil.com")
      expect(sanitized).not_to include("fonts.googleapis.com")
    end

    it "accepts rel attribute case-insensitively" do
      sanitized = described_class.sanitize(%(<link rel="STYLESHEET" href="https://fonts.googleapis.com/css2?family=Inter">))

      expect(sanitized).to include("fonts.googleapis.com")
    end

    it "accepts rel with multiple space-separated values including stylesheet" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet preload" href="https://fonts.googleapis.com/css2?family=Inter">))

      expect(sanitized).to include("fonts.googleapis.com")
    end

    it "rejects rel with comma-separated values (HTML spec requires whitespace)" do
      sanitized = described_class.sanitize(%(<link rel="stylesheet,preload" href="https://fonts.googleapis.com/css2?family=Inter">))

      expect(sanitized).not_to include("fonts.googleapis.com")
    end

    it "preserves safe srcset URLs" do
      sanitized = described_class.sanitize(%(<img srcset="https://static-2.gumroad.com/a.png 1x, https://files.gumroad.com/a.png 2x" alt="Preview">))

      expect(sanitized).to include(%(srcset="https://static-2.gumroad.com/a.png 1x, https://files.gumroad.com/a.png 2x"))
    end

    it "strips javascript URLs from srcset" do
      sanitized = described_class.sanitize(%(<img srcset="https://static-2.gumroad.com/a.png 1x, javascript:alert(1) 2x" alt="Preview">))

      expect(sanitized).not_to include("srcset=")
      expect(sanitized).not_to include("javascript:")
    end

    it "strips executable data document URLs from srcset" do
      sanitized = described_class.sanitize(%(<img srcset="data:text/html,<script>alert(1)</script> 1x" alt="Preview">))

      expect(sanitized).not_to include("srcset=")
      expect(sanitized).not_to include("data:text/html")
    end
  end

  describe ".sanitize_with_report" do
    it "reports stripped tags with attrs and reason" do
      result = described_class.sanitize_with_report(%(<script src="https://evil.com/x.js"></script>))

      expect(result.html).not_to include("evil.com")
      expect(result.report[:removed_tags]).to contain_exactly(
        hash_including(tag: "script", reason: "script src host not allowed")
      )
      expect(result.report[:removed_tags].first[:attrs]["src"]).to eq("https://evil.com/x.js")
      expect(result.report[:total_removed]).to eq(1)
      expect(result.report[:truncated]).to be(false)
    end

    it "reports stripped attributes with the dangerous-URL reason" do
      result = described_class.sanitize_with_report(%(<a href="javascript:alert(1)">Click</a>))

      expect(result.report[:removed_attributes]).to contain_exactly(
        hash_including(tag: "a", attribute: "href", value: "javascript:alert(1)", reason: "javascript: URL blocked")
      )
    end

    it "reports form action removal" do
      result = described_class.sanitize_with_report(%(<form action="https://evil.com"><input></form>))

      expect(result.report[:removed_attributes]).to include(
        hash_including(tag: "form", attribute: "action", reason: "form action removed")
      )
    end

    it "reports the meta-refresh-blocked reason distinctly" do
      result = described_class.sanitize_with_report(%(<meta http-equiv="refresh" content="0;url=https://evil.com">))

      expect(result.report[:removed_tags].first[:reason]).to eq("meta refresh blocked")
    end

    it "caps the report at MAX_REPORT_ENTRIES but still tracks total_removed" do
      cap = Ai::PageSanitizer::MAX_REPORT_ENTRIES
      html = "<script src=\"https://evil.com/x.js\"></script>" * (cap + 25)

      result = described_class.sanitize_with_report(html)

      expect(result.report[:removed_tags].size + result.report[:removed_attributes].size).to eq(cap)
      expect(result.report[:total_removed]).to eq(cap + 25)
      expect(result.report[:truncated]).to be(true)
    end

    it "strips control characters from captured values (no ANSI escape leakage)" do
      input = %(<script src="https://evil.com/\e[31mred\e[0m\x07.js"></script>)
      result = described_class.sanitize_with_report(input)

      captured_src = result.report[:removed_tags].first[:attrs]["src"]
      expect(captured_src).not_to include("\e")
      expect(captured_src).not_to include("\x07")
      expect(captured_src).to include("evil.com")
    end

    it "returns an empty report for clean input" do
      result = described_class.sanitize_with_report("<h1>Hello</h1>")

      expect(result.html).to include("<h1>Hello</h1>")
      expect(result.report[:total_removed]).to eq(0)
      expect(result.report[:removed_tags]).to be_empty
      expect(result.report[:removed_attributes]).to be_empty
    end

    it "returns an empty report for blank input" do
      result = described_class.sanitize_with_report("")

      expect(result.html).to eq("")
      expect(result.report).to eq(described_class.empty_report)
    end
  end
end
