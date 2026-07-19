# frozen_string_literal: true

require "spec_helper"

describe AssetPreview do
  describe "#display_height" do
    it "computes the height scaled to the display width" do
      preview = build(:asset_preview_youtube)
      # Factory oembed info: 356x200. Display width caps at 356 (< 670).
      expect(preview.display_height).to eq(200)
    end

    it "returns nil when the width is zero instead of raising FloatDomainError" do
      # Some oEmbed providers report non-numeric widths (e.g. "auto"), which
      # to_i to 0. Dividing by 0.0 produces NaN and NaN.to_i raises
      # FloatDomainError, which crashed API product serialization (Sentry
      # GUMROAD-ZV). A zero width must degrade to nil dimensions instead.
      preview = build(:asset_preview_youtube)
      preview.oembed["info"]["width"] = "auto"

      expect(preview.display_height).to be_nil
    end
  end

  describe "#as_json" do
    it "serializes without raising when the oembed width is unusable" do
      preview = create(:asset_preview_youtube)
      preview.oembed["info"]["width"] = "auto"

      expect { preview.as_json }.not_to raise_error
      expect(preview.as_json[:height]).to be_nil
    end
  end
end
