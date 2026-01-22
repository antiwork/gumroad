# frozen_string_literal: true
require 'spec_helper'

RSpec.describe Exports::CompileAudienceExportChunksJob, type: :worker do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let(:export) { AudienceExport.create!(seller: seller, recipient: recipient, json_data: { options: { followers: true } }) }
  let(:chunk) { AudienceExportChunk.create!(audience_export: export, json_data: { members_data: [["test@example.com", 1.day.ago.to_s]] }) }

  it 'compiles chunks and sends email' do
    allow(AudienceExportMailer).to receive_message_chain(:export_ready, :deliver_later)
    described_class.new.perform(export.id)
    expect(AudienceExportMailer).to have_received(:export_ready).with(export, anything, export.filename)
  end

  it 'cleans up chunks after compile' do
    described_class.new.perform(export.id)
    expect(export.audience_export_chunks.count).to eq(0)
  end
end
