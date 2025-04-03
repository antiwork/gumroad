# frozen_string_literal: true

require "spec_helper"

describe PurgeOldDeletedAssetPreviewsWorker do
  describe "#perform" do
    it "deletes targeted rows" do
      stub_const("#{described_class}::DELETION_BATCH_SIZE", 1)
      create(:asset_preview, deleted_at: 2.months.ago)
      recently_marked_as_deleted = create(:asset_preview, deleted_at: 1.day.ago)
      not_marked_as_deleted = create(:asset_preview)

      described_class.new.perform
      expect(AssetPreview.all).to match_array([recently_marked_as_deleted, not_marked_as_deleted])
    end
  end
end
