# frozen_string_literal: true

require "spec_helper"

describe SellerProfile do
  describe "#custom_styles" do
    subject { create(:seller_profile, highlight_color: "#009a49", font: "Roboto Mono", background_color: "#000000") }

    it "has CSS for background color, accent color, and font" do
      expect(subject.custom_styles).to include("--accent: 0 154 73;--contrast-accent: 255 255 255")
      expect(subject.custom_styles).to include("--filled: 0 0 0")
      expect(subject.custom_styles).to include("--body-bg: #000000")
      expect(subject.custom_styles).to include("--color: 255 255 255")
      expect(subject.custom_styles).to include("--font-family: \"Roboto Mono\", \"ABC Favorit\", monospace")
    end

    it "rebuilds CSS when custom style attribute is saved" do
      subject.update_attribute(:highlight_color, "#ff90e8")
      expect(Rails.cache.exist?(subject.custom_style_cache_name)).to eq(false)
      expect(subject.custom_styles).to include("--accent: 255 144 232;--contrast-accent: 0 0 0")

      subject.update_attribute(:background_color, "#fff")
      expect(Rails.cache.exist?(subject.custom_style_cache_name)).to eq(false)
      expect(subject.custom_styles).to include("--filled: 255 255 255")
      expect(subject.custom_styles).to include("--color: 0 0 0")

      subject.update_attribute(:font, "ABC Favorit")
      expect(Rails.cache.exist?(subject.custom_style_cache_name)).to eq(false)
      expect(subject.custom_styles).to include("--font-family: \"ABC Favorit\", \"ABC Favorit\", sans-serif")
      expect(Rails.cache.exist?(subject.custom_style_cache_name)).to eq(true)
    end
  end

  describe "#font_family" do
    subject { create(:seller_profile) }

    it "returns the active font, then ABC Favorit and a generic fallback" do
      expect(subject.font_family).to eq(%("ABC Favorit", "ABC Favorit", sans-serif))
    end

    it "returns a serif fallback for a serif font" do
      subject.update!(font: "Domine")
      expect(subject.font_family).to eq(%("Domine", "ABC Favorit", serif))
    end

    it "returns a monospace fallback for a monospace font" do
      subject.update!(font: "Roboto Mono")
      expect(subject.font_family).to eq(%("Roboto Mono", "ABC Favorit", monospace))
    end
  end
end
