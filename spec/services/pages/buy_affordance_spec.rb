# frozen_string_literal: true

require "spec_helper"

describe Pages::BuyAffordance do
  describe ".missing?" do
    it "returns false when the HTML has a data-gumroad-action buy element" do
      html = %(<section><a data-gumroad-action="buy">Buy now</a></section>)

      expect(described_class.missing?(html)).to be(false)
    end

    it "returns false when the HTML posts the gumroad checkout message" do
      html = %(<script>parent.postMessage({ type: "gumroad:checkout" }, "*");</script>)

      expect(described_class.missing?(html)).to be(false)
    end

    it "returns true when the HTML has no buy affordance" do
      html = %(<section><h1>Landing page</h1><p>No checkout path.</p></section>)

      expect(described_class.missing?(html)).to be(true)
    end

    it "returns true when the buy element existed only before sanitization stripped it" do
      html = %(<section><custom-buy data-gumroad-action="buy">Buy</custom-buy><p>Details</p></section>)
      sanitized = Ai::PageSanitizer.sanitize(html)

      expect(sanitized).to include("<p>Details</p>")
      expect(sanitized).not_to include("data-gumroad-action")
      expect(described_class.missing?(sanitized)).to be(true)
    end

    it "returns false for blank HTML" do
      expect(described_class.missing?(nil)).to be(false)
      expect(described_class.missing?("")).to be(false)
    end
  end
end
