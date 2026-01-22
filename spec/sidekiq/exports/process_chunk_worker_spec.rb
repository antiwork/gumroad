# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Exports::ProcessChunkWorker, type: :worker do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let(:export) { AudienceExport.create!(seller: seller, recipient: recipient, json_data: { options: { followers: true } }) }
  let(:member) { seller.audience_members.create!(email: 'test@example.com', min_created_at: 1.day.ago) }
  let(:chunk) { AudienceExportChunk.create!(audience_export: export, json_data: { member_ids: [member.id] }) }

  it 'processes chunk and updates members_data' do
    described_class.new.perform(chunk.id)
    chunk.reload
    expect(chunk.json_data['members_data']).to include([member.email, member.min_created_at.to_s])
  end

  it 'enqueues compile job when all chunks are processed' do
    allow(Exports::CompileChunksWorker).to receive(:perform_async)
    described_class.new.perform(chunk.id)
    expect(Exports::CompileChunksWorker).to have_received(:perform_async).with(export.id)
  end
end
