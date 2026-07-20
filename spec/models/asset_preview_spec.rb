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

  describe "#display_width" do
    it "returns nil when the width is zero, matching display_height's contract" do
      preview = build(:asset_preview_youtube)
      preview.oembed["info"]["width"] = "auto"

      expect(preview.display_width).to be_nil
    end
  end

  describe "#as_json" do
    it "serializes without raising when the oembed width is unusable" do
      preview = create(:asset_preview_youtube)
      preview.oembed["info"]["width"] = "auto"

      expect { preview.as_json }.not_to raise_error
      expect(preview.as_json[:height]).to be_nil
      expect(preview.as_json[:width]).to be_nil
    end

    it "serializes without raising for an existing file cover analyzed as 0x0" do
      # The production trigger for Sentry GUMROAD-ZV: a video file that
      # ffprobe identifies but can't decode gets analyzed as width/height 0.0.
      # New uploads like this are now rejected by validation, but records
      # created before that validation still exist and must serialize.
      preview = create(:asset_preview_mov)
      preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => 0.0, "height" => 0.0))

      expect { preview.as_json }.not_to raise_error
      expect(preview.as_json[:width]).to be_nil
      expect(preview.as_json[:height]).to be_nil
    end
  end

  describe "dimension validation" do
    it "rejects a file whose analyzed dimensions are zero" do
      # A 0x0 "video" (e.g. a truncated or mislabeled file that ffprobe
      # identifies but can't decode) must be rejected at upload time, the same
      # as a file that couldn't be analyzed at all.
      preview = build(:asset_preview_mov, attach: true)
      preview.file.attach(
        Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "thing.mov"), "video/quicktime")
      )
      preview.file.blob.update!(metadata: { "identified" => true, "width" => 0.0, "height" => 0.0, "duration" => 0.04, "video" => true, "analyzed" => true })

      expect(preview).not_to be_valid
      expect(preview.errors[:base]).to include("Could not analyze cover. Please check the uploaded file.")
    end
  end
end
