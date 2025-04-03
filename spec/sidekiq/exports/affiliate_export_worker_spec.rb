# frozen_string_literal: true

describe Exports::AffiliateExportWorker do
  describe "#perform" do
    before do
      @seller = create(:user)
      ActionMailer::Base.deliveries.clear
    end

    it "sends email to seller when it is also the recipient" do
      expect(ContactingCreatorMailer).to receive(:affiliates_data).and_call_original
      described_class.new.perform(@seller.id, @seller.id)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([@seller.email])
    end

    it "sends email to recipient" do
      expect(ContactingCreatorMailer).to receive(:affiliates_data).and_call_original
      recipient = create(:user)
      described_class.new.perform(@seller.id, recipient.id)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([recipient.email])
    end
  end
end
