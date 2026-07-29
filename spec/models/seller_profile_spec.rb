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
      expect(subject.custom_styles).to include("--danger: 220 52 30;--contrast-danger: 255 255 255")
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

    it "expands a legacy three-digit accent colour rather than breaking on it" do
      # Normal saves reject short hex, but legacy raw writes bypassed the validator.
      subject.update_column(:highlight_color, "#0f0")
      subject.reload

      expect(subject.custom_styles).to include("--accent: 0 255 0")
    end

    it "does not compile stored values that can inject SCSS" do
      subject.custom_styles
      subject.update_column(
        :highlight_color,
        "#ffffff\n)}; } body { display:none !important; } :root { --x: \#{split-color(#ffffff"
      )

      expect(subject.reload.custom_styles).to eq("")
    end

    it "does not return cached CSS for an unsafe stored font" do
      subject.custom_styles
      subject.update_column(:font, "Roboto Mono; } body { display: none }")

      expect(subject.reload.custom_styles).to eq("")
    end
  end

  describe "validations" do
    it "rejects a colour with a valid first line and trailing content" do
      subject = build(:seller_profile, highlight_color: "#ffffff\nbody { display: none }")

      expect(subject).not_to be_valid
      expect(subject.errors[:highlight_color]).to include("is not a valid hexadecimal color")
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

  describe "danger colour helpers" do
    it "keeps the standard red when it contrasts with the background" do
      subject = build(:seller_profile, background_color: "#ffffff")

      expect(subject.danger_color).to eq("#dc341e")
      expect(subject.text_color_on_danger).to eq("#ffffff")
    end

    it "uses a darker red on a light background where the standard red is not legible" do
      subject = build(:seller_profile, background_color: "#f8efe3")

      expect(subject.danger_color).to eq("#9b1c12")
      expect(ContrastColor.ratio_between(subject.danger_color, subject.background_color)).to be >= 4.5
    end

    it "falls back to readable neutral text when no red candidate contrasts" do
      subject = build(:seller_profile, background_color: "#dc341e")

      expect(subject.danger_color).to eq("#ffffff")
      expect(subject.text_color_on_danger).to eq("#000000")
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

  describe "#accent_color_for_indicators" do
    it "keeps the saved accent when it is already visible on the background" do
      subject = build(:seller_profile, highlight_color: "#009a49", background_color: "#f8efe3")

      expect(subject.accent_color_for_indicators).to eq("#009a49")
    end

    it "moves an accent that matches the background far enough to be seen" do
      subject = build(:seller_profile, highlight_color: "#ffffff", background_color: "#ffffff")

      indicator = subject.accent_color_for_indicators
      expect(indicator).not_to eq("#ffffff")
      expect(ContrastColor.ratio_between(indicator, "#ffffff")).to be >= ContrastColor::WCAG_AA_NON_TEXT
    end

    it "leaves the saved accent itself untouched" do
      subject = build(:seller_profile, highlight_color: "#ffffff", background_color: "#ffffff")
      subject.accent_color_for_indicators

      expect(subject.highlight_color).to eq("#ffffff")
    end
  end

  describe "font CSS sources" do
    it "builds one Stripe-compatible stylesheet containing every seller font" do
      source = described_class.seller_fonts_css_source

      expect(source).not_to include("ABC%20Favorit")
      described_class::FONT_CHOICES.without("ABC Favorit").each do |font|
        expect(source).to include("family=#{Addressable::URI.encode(font)}:wght@400;600")
      end
    end

    it "builds the active font's storefront stylesheet from the same source" do
      subject = build(:seller_profile, font: "Roboto Mono")

      expect(subject.font_css_source).to eq(
        "https://fonts.googleapis.com/css2?family=Roboto%20Mono:wght@400;600&display=swap"
      )
    end
  end
end
