# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceExportChunk do
  describe "associations" do
    it "belongs to audience_export" do
      export = create(:audience_export)
      chunk = create(:audience_export_chunk, audience_export: export)
      expect(chunk.audience_export).to eq(export)
    end
  end

  describe "serialization" do
    it "serializes member_ids as Array" do
      ids = [1, 2, 3, 4, 5]
      chunk = create(:audience_export_chunk, member_ids: ids)
      chunk.reload
      expect(chunk.member_ids).to eq(ids)
    end

    it "serializes members_data as Array" do
      data = [
        ["user1@example.com", "2024-01-01 00:00:00"],
        ["user2@example.com", "2024-01-02 00:00:00"]
      ]
      chunk = create(:audience_export_chunk, members_data: data)
      chunk.reload
      expect(chunk.members_data).to eq(data)
    end
  end

  describe "defaults" do
    it "defaults processed to false" do
      chunk = create(:audience_export_chunk)
      expect(chunk.processed).to be(false)
    end
  end

  describe "processed flag" do
    it "can be marked as processed" do
      chunk = create(:audience_export_chunk, processed: false)
      chunk.update!(processed: true)
      expect(chunk.reload.processed).to be(true)
    end
  end
end
