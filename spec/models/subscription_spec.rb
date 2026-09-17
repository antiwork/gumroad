# frozen_string_literal: true

require "spec_helper"

describe Subscription do
  describe "#send_restart_notifications!" do
    let(:seller) { create(:named_user) }
    let(:product) { create(:membership_product, user: seller) }
    let(:subscription) { create(:subscription, link: product) }

    it "notifies the buyer, the seller and the webhook" do
      expect(CustomerMailer).to receive(:subscription_restarted).with(subscription.id, nil).and_call_original
      expect(ContactingCreatorMailer).to receive(:subscription_restarted).with(subscription.id).and_call_original
      expect(subscription).to receive(:send_restarted_notification_webhook)

      subscription.send_restart_notifications!
    end

    it "does not notify the seller when they have turned off purchase notifications" do
      seller.update!(enable_payment_email: false)

      expect(CustomerMailer).to receive(:subscription_restarted).with(subscription.id, nil).and_call_original
      expect(ContactingCreatorMailer).not_to receive(:subscription_restarted)
      expect(subscription).to receive(:send_restarted_notification_webhook)

      subscription.send_restart_notifications!
    end
  end
end
