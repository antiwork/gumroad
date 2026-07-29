# frozen_string_literal: true

require "spec_helper"

describe SellerProfile do
  describe "#custom_styles" do
    subject { create(:seller_profile, highlight_color: "#009a49", font: "Roboto Mono", background_color: "#000000") }

    it "has CSS for background color, accent color, and font" do
      # APCA reads white as the readable text colour on this green, but white on #009a49 is only
      # 3.67:1, so the displayed accent is darkened to #008941 (0 137 65) to clear 4.5:1. The saved
      # colour is unchanged and is what --accent carries.
      expect(subject.custom_styles).to include("--accent: 0 154 73;--accent-with-text: 0 137 65")
      expect(subject.custom_styles).to include("--contrast-accent: 255 255 255")
      expect(subject.reload.highlight_color).to eq("#009a49")
      expect(subject.custom_styles).to include("--filled: 0 0 0")
      expect(subject.custom_styles).to include("--body-bg: #000000")
      expect(subject.custom_styles).to include("--color: 255 255 255")
      expect(subject.custom_styles).to include("--font-family: \"Roboto Mono\", \"ABC Favorit\", monospace")
    end

    it "rebuilds CSS when custom style attribute is saved" do
      subject.update_attribute(:highlight_color, "#ff90e8")
      expect(Rails.cache.exist?(subject.custom_style_cache_name)).to eq(false)
      expect(subject.custom_styles).to include("--accent: 255 144 232;--accent-with-text: 255 144 232;--contrast-accent: 0 0 0")

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

      expect(subject.custom_styles).to include("--accent: 25 255 29;--accent-with-text: 25 255 29;--contrast-accent: 0 0 0")
    end

    it "gives a saturated red accent white text by darkening only the displayed colour" do
      # The regression this replaced: black narrowly wins the WCAG comparison on #ff0000 (5.25:1 vs
      # 4.00:1), so a red pay button rendered its price in black, which sellers read as broken.
      subject.update_attribute(:highlight_color, "#ff0000")

      expect(subject.custom_styles).to include("--accent: 255 0 0;--accent-with-text: 238 0 0")
      expect(subject.custom_styles).to include("--contrast-accent: 255 255 255")
      expect(subject.reload.highlight_color).to eq("#ff0000")
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

    it "leaves an accent that can already carry readable text exactly as the seller saved it" do
      expect(subject.accent_color_for_text_areas).to eq("#19ff1d")
      expect(subject.highlight_color).to eq("#19ff1d")
    end

    it "picks text that contrasts with the body text colour for filled primary surfaces" do
      # --primary is the body text colour, so --contrast-primary sits on top of that.
      expect(subject.text_color_on_primary).to eq("#000000")
    end
  end

  describe "#accent_styles" do
    subject { create(:seller_profile, highlight_color: "#009a49", font: "Roboto Mono", background_color: "#000000") }

    it "emits the accent trio and nothing else" do
      # Same colour maths as #custom_styles above: white on #009a49 is only 3.67:1, so the displayed
      # accent darkens to #008941 (0 137 65) while --accent keeps the seller's saved colour.
      expect(subject.accent_styles).to eq(":root{--accent:0 154 73;--accent-with-text:0 137 65;--contrast-accent:255 255 255}")
    end

    it "leaves the page chrome alone" do
      # The whole point of this being separate from #custom_styles: checkout takes the accent without
      # inheriting the seller's background, body text colour or font.
      %w[--body-bg --font-family --color --filled --primary body].each do |chrome|
        expect(subject.accent_styles).not_to include(chrome)
      end
    end

    it "produces the same RGB triples as the full stylesheet for the same colours" do
      # rgb_triplet re-implements the SCSS split-color() function, so the two paths must not drift.
      # Asserted against #custom_styles rather than literals so a change to either side is caught.
      expect(subject.custom_styles).to include("--accent: 0 154 73")
      expect(subject.accent_styles).to include("--accent:0 154 73")
    end

    it "handles a colour whose channels have leading zeroes" do
      # "#0a0b0c" is the case a naive to_i gets wrong by dropping each channel's leading zero.
      subject.update!(highlight_color: "#0a0b0c")

      expect(subject.accent_styles).to include("--accent:10 11 12")
    end

    it "expands a legacy three-digit colour rather than truncating it" do
      # HexColorValidator only runs on normal saves, so update_column and raw SQL have written
      # three-digit values historically. Splitting into pairs would drop the trailing digit and emit
      # a one-number accent, which is not a valid colour — the pay button and focus rings would lose
      # their colour on checkout while the seller's storefront still rendered correctly.
      subject.update_column(:highlight_color, "#0f0")
      subject.reload

      expect(subject.accent_styles).to include("--accent:0 255 0")
    end

    it "emits nothing at all when the stored colour cannot be parsed" do
      # A malformed --accent unsets the pay button's colour, which is worse on a payment page than
      # keeping Gumroad's default palette. Multiline values are persistable because the validator's
      # regex anchors per line rather than per string.
      subject.update_column(:highlight_color, "#abcdef\n} body{display:none}")
      subject.reload

      expect(subject.accent_styles).to be_nil
    end

    it "is invalidated when the seller changes their accent colour" do
      # The after_save hook clears both cache keys. Without the accent_styles deletion this returns
      # the stale colour forever, so checkout and the storefront disagree.
      expect(subject.accent_styles).to include("--accent:0 154 73")

      subject.update!(highlight_color: "#ff0000")

      expect(subject.accent_styles).to include("--accent:255 0 0")
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
