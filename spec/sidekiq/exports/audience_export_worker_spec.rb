# frozen_string_literal: true

describe Exports::AudienceExportWorker do
  describe "#perform" do
    let(:seller) { create(:user) }
    let(:audience_options) { { followers: true } }
    let(:recipient) { create(:user) }

    before do
      ActionMailer::Base.deliveries.clear
    end

    it "sends email to seller when it is also the recipient" do
      expect(ContactingCreatorMailer).to receive(:subscribers_data).and_call_original
      described_class.new.perform(seller.id, seller.id, audience_options)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([seller.email])
    end

    it "sends email to recipient" do
      expect(ContactingCreatorMailer).to receive(:subscribers_data).and_call_original
      described_class.new.perform(seller.id, recipient.id, audience_options)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([recipient.email])
    end
  end
end
