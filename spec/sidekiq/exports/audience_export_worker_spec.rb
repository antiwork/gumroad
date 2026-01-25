# frozen_string_literal: true

describe Exports::AudienceExportWorker do
  describe "#perform" do
    let(:seller) { create(:user) }
    let(:audience_options) { { followers: true } }
    let(:recipient) { create(:user) }

    it "creates an AudienceExport with seller as recipient when seller is also the recipient" do
      expect do
        described_class.new.perform(seller.id, seller.id, audience_options)
      end.to change(AudienceExport, :count).by(1)

      export = AudienceExport.last
      expect(export.seller).to eq(seller)
      expect(export.recipient).to eq(seller)
      expect(export.audience_options).to eq(audience_options)
    end

    it "creates an AudienceExport with separate recipient" do
      expect do
        described_class.new.perform(seller.id, recipient.id, audience_options)
      end.to change(AudienceExport, :count).by(1)

      export = AudienceExport.last
      expect(export.seller).to eq(seller)
      expect(export.recipient).to eq(recipient)
    end

    it "enqueues CreateAndEnqueueChunksWorker" do
      described_class.new.perform(seller.id, recipient.id, audience_options)

      export = AudienceExport.last
      expect(Exports::Audience::CreateAndEnqueueChunksWorker).to have_enqueued_sidekiq_job(export.id)
    end
  end
end
