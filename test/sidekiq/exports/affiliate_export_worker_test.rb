# frozen_string_literal: true

require "test_helper"

class ExportsAffiliateExportWorkerTest < ActiveSupport::TestCase
  self.described_class = Exports::AffiliateExportWorker


  context_ Exports::AffiliateExportWorker do
  context_ "#perform" do
      before do
        @seller = create(:user)
        ActionMailer::Base.deliveries.clear
      end

  test "sends email to seller when it is also the recipient" do
        expect(ContactingCreatorMailer).to receive(:affiliates_data).and_call_original
        described_class.new.perform(@seller.id, @seller.id)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([@seller.email])
      end

  test "sends email to recipient" do
        expect(ContactingCreatorMailer).to receive(:affiliates_data).and_call_original
        recipient = create(:user)
        described_class.new.perform(@seller.id, recipient.id)

        mail = ActionMailer::Base.deliveries.last
        expect(mail.to).to eq([recipient.email])
      end
    end
  end
end
