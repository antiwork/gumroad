# frozen_string_literal: true

require "spec_helper"

describe FeaturesMarkdownGenerator do
  describe ".call" do
    it "returns markdown containing all feature categories" do
      result = described_class.call

      expect(result).to include("# Gumroad features")
      expect(result).to include("## Products")
      expect(result).to include("## Payments & checkout")
      expect(result).to include("## Payouts")
      expect(result).to include("## Content & delivery")
      expect(result).to include("## Profile & discovery")
      expect(result).to include("## Marketing & engagement")
      expect(result).to include("## Integrations")
      expect(result).to include("## Analytics & reporting")
      expect(result).to include("## Admin & developer tools")
      expect(result).to include("## Subscriptions & memberships")
    end

    it "includes the current date" do
      result = described_class.call

      expect(result).to include(Date.current.strftime("%B %-d, %Y"))
    end

    it "links to the features page" do
      result = described_class.call

      expect(result).to include("gumroad.com/features")
    end
  end
end
