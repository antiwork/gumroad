# frozen_string_literal: true

require "spec_helper"

describe Subscription do
  describe "#cancel!" do
    let(:product) { create(:product, :with_installment_plan, price_cents: 10_00) }
    let(:subscription) { create(:subscription, link: product, user: create(:user), is_installment_plan: true) }

    before do
      build(:purchase, link: product, subscription:, is_original_subscription_purchase: true, price_cents: 0).save!
    end

    it "refuses a buyer-initiated cancel of an installment plan and leaves the row untouched" do
      expect { subscription.cancel!(by_seller: false) }
        .to raise_error(ActiveRecord::RecordInvalid, /cannot be cancelled by the customer/)

      subscription.reload
      expect(subscription.cancelled_at).to be_nil
      expect(subscription.user_requested_cancellation_at).to be_nil
    end

    it "cancels an installment plan when an admin runs it on the buyer's behalf" do
      subscription.cancel!(by_seller: false, by_admin: true)

      subscription.reload
      expect(subscription.cancelled_at).to be_present
      expect(subscription.cancelled_by_admin?).to be(true)
    end
  end
end
