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
  end
end
