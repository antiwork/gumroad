# frozen_string_literal: true

require "spec_helper"

describe AudienceExportChunk do
  describe "associations" do
    it { is_expected.to belong_to(:export).class_name("AudienceExport") }
  end

  describe "serialization" do
    it "serializes audience_member_ids as YAML" do
      chunk = create(:audience_export_chunk, audience_member_ids: [1, 2, 3])
      chunk.reload
      expect(chunk.audience_member_ids).to eq([1, 2, 3])
    end

    it "serializes audience_data as YAML" do
      data = [["test@example.com", Time.current.to_s]]
      chunk = create(:audience_export_chunk, audience_data: data)
      chunk.reload
      expect(chunk.audience_data).to eq(data)
    end
  end
end
