# frozen_string_literal: true

require "spec_helper"

describe ContrastColor do
  describe ".for" do
    it "picks black on a bright accent colour that HSL lightness misjudged as dark" do
      # The bug this module exists to fix. #19ff1d sits at 54.9% HSL lightness, just under the old
      # 55% cutoff, so it used to get white text at 1.37:1 — unreadable. Black is 15.36:1.
      expect(described_class.for("#19ff1d")).to eq("#000000")
    end

    it "still picks white on genuinely dark colours" do
      expect(described_class.for("#000000")).to eq("#ffffff")
      expect(described_class.for("#0a0a0a")).to eq("#ffffff")
      expect(described_class.for("#333333")).to eq("#ffffff")
    end

    it "picks black on a mid-tone green that used to get white text below the AA minimum" do
      # #009a49 was the accent colour in this repo's own seller-profile spec, asserted as getting
      # white text. White on it is 3.67:1, which fails WCAG AA; black is 5.72:1. The old rule was
      # producing a second, quieter violation on top of the reported one.
      expect(described_class.for("#009a49")).to eq("#000000")
      expect(described_class.ratio_between("#009a49", "#ffffff")).to be < ContrastColor::WCAG_AA_NORMAL_TEXT
      expect(described_class.ratio_between("#009a49", "#000000")).to be > ContrastColor::WCAG_AA_NORMAL_TEXT
    end

    it "still picks black on genuinely light colours" do
      expect(described_class.for("#ffffff")).to eq("#000000")
      expect(described_class.for("#ff90e8")).to eq("#000000")
    end

    it "is case insensitive and tolerates surrounding whitespace" do
      expect(described_class.for("#19FF1D")).to eq("#000000")
      expect(described_class.for("  #19ff1d  ")).to eq("#000000")
    end

    it "handles the 3-digit hex form the same way as its 6-digit equivalent" do
      # The colour column is only validated on normal saves, so `update_attribute` and friends can
      # store a 3-digit value — and the SCSS `lightness()` this replaced understood that form. If
      # it fell through to the invalid-value fallback, a black background would silently get black
      # text on it.
      expect(described_class.for("#000")).to eq(described_class.for("#000000")).and eq("#ffffff")
      expect(described_class.for("#fff")).to eq(described_class.for("#ffffff")).and eq("#000000")
      expect(described_class.for("#f0a")).to eq(described_class.for("#ff00aa"))
    end

    it "falls back to black rather than raising on a value that isn't a hex colour" do
      ["", nil, "red", "#ffff", "#gggggg", "#19ff1d; }"].each do |invalid|
        expect(described_class.for(invalid)).to eq("#000000")
      end
    end

    it "does not depend on which side of a lightness threshold a colour falls" do
      # #19ff1d and #1aff1e are visually identical but land on opposite sides of the old 55% HSL
      # cutoff, which is why support had to nudge a seller's colour by one hex step as a
      # workaround. Both must now resolve the same way.
      expect(described_class.for("#19ff1d")).to eq(described_class.for("#1aff1e"))
    end
  end

  describe ".ratio_between" do
    it "computes WCAG contrast ratios" do
      expect(described_class.ratio_between("#ffffff", "#000000")).to be_within(0.01).of(21.0)
      expect(described_class.ratio_between("#ffffff", "#19ff1d")).to be_within(0.01).of(1.37)
      expect(described_class.ratio_between("#000000", "#19ff1d")).to be_within(0.01).of(15.36)
    end

    it "is symmetric" do
      expect(described_class.ratio_between("#19ff1d", "#000000"))
        .to eq(described_class.ratio_between("#000000", "#19ff1d"))
    end

    it "returns nil when either colour isn't a hex colour" do
      expect(described_class.ratio_between("#ffffff", "nope")).to be_nil
      expect(described_class.ratio_between("nope", "#ffffff")).to be_nil
    end
  end

  describe "the readability guarantee" do
    # This is the point of the whole module: it is not merely "better than the old threshold", it
    # makes an unreadable result impossible. Whichever of black or white contrasts more against a
    # colour is always at least 4.58:1, which clears WCAG AA's 4.5:1 for normal-size text. So no
    # colour a seller can pick can produce unreadable text.
    #
    # Sampling every 5th value per channel covers ~140k colours and includes the true worst case
    # (#cf0dcc, 4.5826:1). A full 16.7M sweep confirms the same floor but is too slow for CI.
    it "never produces text below the WCAG AA minimum, for any colour a seller can pick" do
      worst_ratio = Float::INFINITY
      worst_color = nil

      (0..255).step(5) do |r|
        (0..255).step(5) do |g|
          (0..255).step(5) do |b|
            color = format("#%02x%02x%02x", r, g, b)
            ratio = described_class.ratio_between(color, described_class.for(color))

            if ratio < worst_ratio
              worst_ratio = ratio
              worst_color = color
            end
          end
        end
      end

      expect(worst_ratio).to be >= ContrastColor::WCAG_AA_NORMAL_TEXT,
                             "#{worst_color} only reaches #{worst_ratio.round(2)}:1"
      expect(worst_ratio).to be_within(0.01).of(ContrastColor::WORST_CASE_CONTRAST_RATIO)
    end

    it "beats the old HSL-lightness rule on the colours where the two disagree" do
      # Reimplements the old rule so the improvement is demonstrated rather than asserted.
      old_rule = lambda do |hex|
        channels = [hex[1, 2], hex[3, 2], hex[5, 2]].map { _1.to_i(16) / 255.0 }
        (channels.min + channels.max) / 2 < 0.55 ? "#ffffff" : "#000000"
      end

      disagreements = 0

      (0..255).step(15) do |r|
        (0..255).step(15) do |g|
          (0..255).step(15) do |b|
            color = format("#%02x%02x%02x", r, g, b)
            next if old_rule.call(color) == described_class.for(color)

            disagreements += 1
            expect(described_class.ratio_between(color, described_class.for(color)))
              .to be > described_class.ratio_between(color, old_rule.call(color))
          end
        end
      end

      # Guards against the comparison silently passing because nothing ever disagreed.
      expect(disagreements).to be > 0
    end
  end

  describe ".accessible_accent" do
    it "gives a saturated red pay button white text, by darkening the displayed red slightly" do
      # The bug this method exists to fix. On #ff0000, black's WCAG ratio (5.25:1) marginally beats
      # white's (4.00:1), so the plain two-way comparison picked black — which sellers read as
      # broken. APCA agrees with them that white is the readable choice, and darkening the red by
      # 17/255 of the way toward black gets white over the 4.5:1 line.
      result = described_class.accessible_accent("#ff0000")

      expect(result[:text]).to eq("#ffffff")
      expect(result[:accent]).to eq("#ee0000")
      expect(described_class.ratio_between(result[:accent], result[:text])).to be >= ContrastColor::WCAG_AA_NORMAL_TEXT
    end

    it "picks black on bright green and on orange" do
      # The population the previous fix was for: white on these is invisible (1.37:1 and 1.54:1).
      # Black clears the floor outright on both, so the seller's colour is left exactly as saved.
      expect(described_class.accessible_accent("#19ff1d")).to eq(accent: "#19ff1d", text: "#000000")
      expect(described_class.accessible_accent("#ffc900")).to eq(accent: "#ffc900", text: "#000000")
    end

    it "picks white on a saturated blue" do
      expect(described_class.accessible_accent("#0000ff")).to eq(accent: "#0000ff", text: "#ffffff")
      expect(described_class.accessible_accent("#1a4bff")).to eq(accent: "#1a4bff", text: "#ffffff")
    end

    it "leaves the accent untouched whenever the preferred text colour already clears the floor" do
      ["#19ff1d", "#ffc900", "#0000ff", "#ff90e8", "#ffffff", "#000000", "#767676", "#ec0000"].each do |hex|
        expect(described_class.accessible_accent(hex)[:accent]).to eq(hex),
                                                                   "expected #{hex} to be displayed unchanged"
      end
    end

    it "changes the accent by the smallest amount that clears the floor" do
      # Provably minimal rather than merely sufficient: the step below the one chosen must fail.
      # Uses the same mixing function the implementation uses, so "one step less" is genuinely the
      # candidate the search rejected rather than a nearby colour that happens to fail.
      { "#ff0000" => "#ffffff", "#009a49" => "#ffffff" }.each do |hex, text|
        rgb = [hex[1, 2], hex[3, 2], hex[5, 2]].map { _1.to_i(16) }
        chosen_step = described_class.brightness_shift_for(rgb, white_text: text == "#ffffff")
        expect(chosen_step).to be > 0, "#{hex} needed no adjustment, so this case proves nothing"

        accent = described_class.accessible_accent(hex).fetch(:accent)
        expect(accent).to eq(described_class.to_hex(described_class.shift_brightness(rgb, white_text: text == "#ffffff", step: chosen_step)))
        expect(described_class.ratio_between(accent, text)).to be >= ContrastColor::WCAG_AA_NORMAL_TEXT

        one_step_less = described_class.to_hex(described_class.shift_brightness(rgb, white_text: text == "#ffffff", step: chosen_step - 1))
        expect(described_class.ratio_between(one_step_less, text)).to be < ContrastColor::WCAG_AA_NORMAL_TEXT,
                                                                      "#{one_step_less} already passes, so #{accent} is not minimal for #{hex}"
      end
    end

    it "leaves the seller's saved colour alone" do
      # The reviewer's hard constraint: this is a display-time adjustment only, so calling it must
      # not be able to write anything back.
      profile = create(:seller_profile, highlight_color: "#ff0000")

      expect(described_class.accessible_accent(profile.highlight_color)[:accent]).to eq("#ee0000")
      expect(profile.reload.highlight_color).to eq("#ff0000")
    end

    it "moves the contrast ratio in one direction only, so the search's answer is the minimum" do
      # The binary search assumes monotonicity: mixing steadily toward black (with white text) or
      # toward white (with black text) only ever increases contrast against that text colour.
      # Channel flooring could in principle break that; this walks every step on a handful of colours
      # spanning the space and asserts it does not.
      %w[#ff0000 #009a49 #0087ff #7b2ff7 #123456 #abcdef].each do |hex|
        rgb = [hex[1, 2], hex[3, 2], hex[5, 2]].map { _1.to_i(16) }

        [true, false].each do |white_text|
          text = white_text ? "#ffffff" : "#000000"
          ratios = (0..255).map do |step|
            described_class.ratio_between(described_class.to_hex(described_class.shift_brightness(rgb, white_text:, step:)), text)
          end

          drops = ratios.each_cons(2).filter_map { |before, after| "#{before.round(4)} -> #{after.round(4)}" if after < before - 1e-9 }
          expect(drops).to be_empty, "#{hex} with #{text} text is not monotone: #{drops.first(3).join(', ')}"
        end
      end
    end

    it "never shifts a seller's colour by more than a barely-perceptible amount" do
      # A readability fix that visibly recolours a storefront is not a fix. The sweep pins the
      # largest shift the algorithm ever applies, in 0-255 steps of the mix toward black or white.
      worst_shift = 0
      worst_color = nil

      (0..255).step(9) do |r|
        (0..255).step(9) do |g|
          (0..255).step(9) do |b|
            color = format("#%02x%02x%02x", r, g, b)
            rendered = described_class.accessible_accent(color).fetch(:accent)
            shift = [r, g, b].each_with_index.map { |channel, index| (channel - rendered[1 + (index * 2), 2].to_i(16)).abs }.max

            if shift > worst_shift
              worst_shift = shift
              worst_color = color
            end
          end
        end
      end

      expect(worst_shift).to be <= ContrastColor::WORST_CASE_BRIGHTNESS_SHIFT,
                             "#{worst_color} moved by #{worst_shift} of 255"
    end

    it "never returns a pair below the WCAG AA minimum, for any colour a seller can pick" do
      # The floor from the previous fix is the good part and must survive this change. Same sampling
      # density as the `.for` sweep above.
      failures = []

      (0..255).step(5) do |r|
        (0..255).step(5) do |g|
          (0..255).step(5) do |b|
            color = format("#%02x%02x%02x", r, g, b)
            pair = described_class.accessible_accent(color)
            ratio = described_class.ratio_between(pair[:accent], pair[:text])

            failures << "#{color} -> #{pair[:accent]} on #{pair[:text]} = #{ratio.round(2)}:1" if ratio < ContrastColor::WCAG_AA_NORMAL_TEXT
          end
        end
      end

      expect(failures).to be_empty, failures.first(5).join("; ")
    end

    it "resolves visually identical colours identically" do
      # The failure mode this replaces: #ec0000 and #ed0000 are the same red to the eye but landed on
      # opposite sides of the crossover, so one got white text and the other black.
      %w[#eb0000 #ec0000 #ed0000 #ee0000 #ef0000 #f00000].each do |hex|
        expect(described_class.accessible_accent(hex)[:text]).to eq("#ffffff"), "#{hex} did not get white text"
      end
    end

    it "handles the 3-digit hex form the same way as its 6-digit equivalent" do
      expect(described_class.accessible_accent("#f0a")).to eq(described_class.accessible_accent("#ff00aa"))
      expect(described_class.accessible_accent("#000")).to eq(described_class.accessible_accent("#000000"))
    end

    it "trims exactly the whitespace JavaScript's String#trim removes" do
      # The browser half of this pair trims with String#trim, which removes more than Ruby's
      # String#strip does — a non-breaking space or a byte-order mark included. If the two disagree,
      # a stored value carrying one (reachable via update_column or raw SQL, which skip the
      # validator) parses in the editor and falls back to the default on the live storefront.
      javascript_trim_characters = [
        "\u0009", "\u000a", "\u000b", "\u000c", "\u000d", "\u0020", "\u00a0", "\u1680",
        "\u2000", "\u2001", "\u2002", "\u2003", "\u2004", "\u2005", "\u2006", "\u2007",
        "\u2008", "\u2009", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000", "\ufeff"
      ]

      javascript_trim_characters.each do |character|
        expect(described_class.accessible_accent("#{character}#ff0000#{character}"))
          .to eq(accent: "#ee0000", text: "#ffffff"), "U+#{format('%04X', character.ord)} was not trimmed"
      end
    end

    it "falls back to a readable pair rather than raising on a value that isn't a hex colour" do
      ["", nil, "red", "#ffff", "#gggggg"].each do |invalid|
        expect(described_class.accessible_accent(invalid)).to eq(accent: "#000000", text: "#ffffff")
      end
    end

    it "matches the browser implementation on every colour in the shared fixture" do
      # app/javascript/utils/color.ts renders the editor preview while this renders the live
      # storefront, so any divergence shows a seller one colour while setting up and another on
      # their store. The fixture was generated from THIS implementation, so the load-bearing half of
      # the pair is color.test.ts asserting the same file — this side is the regression guard that
      # stops a Ruby change from silently editing the contract the browser is held to. Each pair is
      # also re-checked against the WCAG floor here, so a wrong fixture value cannot pass both.
      fixture = JSON.parse(File.read(Rails.root.join("spec", "fixtures", "accent_contrast_pairs.json")))
      expect(fixture.size).to be >= 40

      fixture.each do |expected|
        result = described_class.accessible_accent(expected.fetch("input"))
        expect(result[:accent]).to eq(expected.fetch("accent")), "accent for #{expected['input']}"
        expect(result[:text]).to eq(expected.fetch("text")), "text for #{expected['input']}"
        expect(described_class.ratio_between(expected.fetch("accent"), expected.fetch("text")))
          .to be >= ContrastColor::WCAG_AA_NORMAL_TEXT, "fixture pair for #{expected['input']} is below the floor"
      end
    end
  end
end
