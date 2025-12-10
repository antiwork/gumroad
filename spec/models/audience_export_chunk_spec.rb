# frozen_string_literal: true

require "spec_helper"

RSpec.describe AudienceExportChunk do
  it "belongs to export" do
    export = create(:audience_export)
    chunk = create(:audience_export_chunk, export:)
    expect(chunk.export).to eq(export)
  end

  it "serializes member_ids as array" do
    chunk = create(:audience_export_chunk, member_ids: [1, 2, 3])
    chunk.reload
    expect(chunk.member_ids).to eq([1, 2, 3])
  end

  it "serializes members_data as array" do
    data = [["test@example.com", Time.current.to_s]]
    chunk = create(:audience_export_chunk, members_data: data)
    chunk.reload
    expect(chunk.members_data).to be_an(Array)
    expect(chunk.members_data.first).to eq(["test@example.com", Time.current.to_s])
  end
end
