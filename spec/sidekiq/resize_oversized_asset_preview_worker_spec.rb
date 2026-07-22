# frozen_string_literal: true

require "spec_helper"

describe ResizeOversizedAssetPreviewWorker do
  describe "#perform" do
    it "resizes the cover" do
      asset_preview = create(:asset_preview)
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:resize_oversized_image!)

      described_class.new.perform(asset_preview.id)

      expect(asset_preview).to have_received(:resize_oversized_image!)
    end

    it "does nothing for a deleted or missing cover" do
      asset_preview = create(:asset_preview)
      asset_preview.mark_deleted!
      allow(AssetPreview).to receive(:find_by).and_call_original
      allow(AssetPreview).to receive(:find_by).with(id: asset_preview.id).and_return(asset_preview)
      allow(asset_preview).to receive(:resize_oversized_image!)

      expect { described_class.new.perform(asset_preview.id) }.not_to raise_error
      expect { described_class.new.perform(0) }.not_to raise_error
      expect(asset_preview).not_to have_received(:resize_oversized_image!)
    end
  end
end
