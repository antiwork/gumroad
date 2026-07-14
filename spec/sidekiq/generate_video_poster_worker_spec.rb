# frozen_string_literal: true

require "spec_helper"

describe GenerateVideoPosterWorker do
  describe "#perform" do
    it "generates the poster frame for the cover" do
      asset_preview = create(:asset_preview_mov)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_video_poster!).and_return("https://files.example.com/poster.jpg")

      described_class.new.perform(asset_preview.id)

      expect(asset_preview).to have_received(:generate_video_poster!)
    end

    it "invalidates the product cache when a poster was generated" do
      asset_preview = create(:asset_preview_mov)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_video_poster!).and_return("https://files.example.com/poster.jpg")
      allow(asset_preview.link).to receive(:invalidate_cache)

      described_class.new.perform(asset_preview.id)

      expect(asset_preview.link).to have_received(:invalidate_cache)
    end

    it "does not invalidate the product cache when generation produced no poster" do
      asset_preview = create(:asset_preview_mov)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_video_poster!).and_return(nil)
      allow(asset_preview.link).to receive(:invalidate_cache)

      described_class.new.perform(asset_preview.id)

      expect(asset_preview.link).not_to have_received(:invalidate_cache)
    end

    it "does nothing for a deleted or missing cover" do
      asset_preview = create(:asset_preview_mov)
      asset_preview.mark_deleted!
      allow(AssetPreview).to receive(:find_by).and_call_original
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_video_poster!)

      expect { described_class.new.perform(asset_preview.id) }.not_to raise_error
      expect { described_class.new.perform(0) }.not_to raise_error
      expect(asset_preview).not_to have_received(:generate_video_poster!)
    end
  end
end
