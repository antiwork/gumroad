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

    it "allows style blocks" do
      sanitized = described_class.sanitize(%(<style>.hero { color: red; }</style><section class="hero">Hi</section>))

      expect(sanitized).to include("<style>.hero { color: red; }</style>")
    end

    it "allows Tailwind CDN script tags" do
      sanitized = described_class.sanitize(%(<script src="https://cdn.tailwindcss.com"></script>))

      expect(sanitized).to include(%(<script src="https://cdn.tailwindcss.com"></script>))
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

    it "strips meta refresh tags" do
      sanitized = described_class.sanitize(%(<meta http-equiv="refresh" content="0;url=https://evil.com"><p>Stay</p>))

      expect(sanitized).not_to include("http-equiv")
      expect(sanitized).to include("<p>Stay</p>")
    end

    it "adds sandbox attributes to iframes without one" do
      sanitized = described_class.sanitize(%(<iframe src="https://example.com/embed"></iframe>))

      expect(sanitized).to include(%(sandbox="allow-scripts"))
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
  end
end
