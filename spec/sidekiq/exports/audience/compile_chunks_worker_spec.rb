# frozen_string_literal: true

require "spec_helper"

describe Exports::Audience::CompileChunksWorker do
  let(:seller) { create(:user) }
  let(:recipient) { create(:user) }
  let(:export) { create(:audience_export, seller:, recipient:, options: { followers: true }) }

  let!(:chunk1) do
    create(:audience_export_chunk, export:,
      member_ids: [1, 2],
      csv_data: [["member1@example.com", "2024-01-01"], ["member2@example.com", "2024-01-02"]],
      processed: true)
  end
  let!(:chunk2) do
    create(:audience_export_chunk, export:,
      member_ids: [3],
      csv_data: [["member3@example.com", "2024-01-03"]],
      processed: true)
  end

  describe "#perform" do
    it "sends email with compiled CSV" do
      expect(ContactingCreatorMailer).to receive(:subscribers_data).and_call_original

      described_class.new.perform(export.id)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to include(recipient.email)
    end

    it "cleans up export and chunks after sending" do
      described_class.new.perform(export.id)

      expect(AudienceExport.find_by(id: export.id)).to be_nil
      expect(AudienceExportChunk.where(export_id: export.id).count).to eq(0)
    end

    it "generates correct CSV content" do
      tempfile = nil
      allow(ContactingCreatorMailer).to receive(:subscribers_data) do |args|
        tempfile = args[:tempfile]
        double(deliver_now: true)
      end

      described_class.new.perform(export.id)

      rows = CSV.parse(tempfile.read)
      expect(rows.size).to eq(4)
      expect(rows[0]).to eq(["Subscriber Email", "Subscribed Time"])
      expect(rows[1..].map(&:first)).to contain_exactly(
        "member1@example.com", "member2@example.com", "member3@example.com"
      )
    end
  end
end
