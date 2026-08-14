# frozen_string_literal: true

require "spec_helper"

describe ProcessAssetPreviewRetinaWorker do
  describe "#perform" do
    it "generates the retina variant for the cover" do
      asset_preview = create(:asset_preview)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_retina_variant!).and_return("https://files.example.com/retina.jpg")

      described_class.new.perform(asset_preview.id)

      expect(asset_preview).to have_received(:generate_retina_variant!)
    end

    it "invalidates the product cache when a variant was generated" do
      asset_preview = create(:asset_preview)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_retina_variant!).and_return("https://files.example.com/retina.jpg")
      allow(asset_preview.link).to receive(:invalidate_cache)

      described_class.new.perform(asset_preview.id)

      expect(asset_preview.link).to have_received(:invalidate_cache)
    end

    it "does not invalidate the product cache when generation produced no url" do
      asset_preview = create(:asset_preview)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_retina_variant!).and_return(nil)
      allow(asset_preview.link).to receive(:invalidate_cache)

      described_class.new.perform(asset_preview.id)

      expect(asset_preview.link).not_to have_received(:invalidate_cache)
    end

    it "does nothing for a deleted or missing cover" do
      asset_preview = create(:asset_preview)
      asset_preview.mark_deleted!
      allow(AssetPreview).to receive(:find_by).and_call_original
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:generate_retina_variant!)

      expect { described_class.new.perform(asset_preview.id) }.not_to raise_error
      expect { described_class.new.perform(0) }.not_to raise_error
      expect(asset_preview).not_to have_received(:generate_retina_variant!)
    end
  end
end
