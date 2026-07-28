# frozen_string_literal: true

require "spec_helper"

describe SellerProfile do
  describe "#custom_styles" do
    subject { create(:seller_profile, highlight_color: "#009a49", font: "Roboto Mono", background_color: "#000000") }

    it "has CSS for background color, accent color, and font" do
      # White on #009a49 is 3.67:1, below the WCAG AA minimum, so the accent gets black text.
      expect(subject.custom_styles).to include("--accent: 0 154 73;--contrast-accent: 0 0 0")
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

    it "picks the accent text colour by contrast, not by HSL lightness" do
      # A bright green accent reads as "dark" to HSL lightness (54.9%, just under the old 55%
      # cutoff) and used to get white text at 1.37:1. Black is 15.36:1 against it.
      subject.update_attribute(:highlight_color, "#19ff1d")

      expect(subject.custom_styles).to include("--accent: 25 255 29;--contrast-accent: 0 0 0")
    end

    it "gives the same accent text colour to visually identical colours either side of the old cutoff" do
      subject.update_attribute(:highlight_color, "#19ff1d")
      just_under_the_old_cutoff = subject.custom_styles[/--contrast-accent: [\d ]+/]

      subject.update_attribute(:highlight_color, "#1aff1e")
      just_over_the_old_cutoff = subject.custom_styles[/--contrast-accent: [\d ]+/]

      expect(just_under_the_old_cutoff).to eq(just_over_the_old_cutoff)
    end
  end

  describe "text colour helpers" do
    subject { create(:seller_profile, highlight_color: "#19ff1d", background_color: "#0a0a0a") }

    it "picks readable text for the accent and background colours" do
      expect(subject.text_color_on_highlight).to eq("#000000")
      expect(subject.text_color_on_background).to eq("#ffffff")
    end

    it "picks text that contrasts with the body text colour for filled primary surfaces" do
      # --primary is the body text colour, so --contrast-primary sits on top of that.
      expect(subject.text_color_on_primary).to eq("#000000")
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
