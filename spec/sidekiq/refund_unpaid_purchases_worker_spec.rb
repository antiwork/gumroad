# frozen_string_literal: true

require "spec_helper"

describe RefundUnpaidPurchasesWorker, :vcr do
  describe "#perform" do
    before do
      @admin_user = create(:admin_user)
      @purchase = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase.process!
      @purchase.mark_successful!
      @purchase.increment_sellers_balance!

      @purchase_without_balance = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase_without_balance.process!
      @purchase_without_balance.mark_successful!

      @purchase_with_paid_balance = create(:purchase_in_progress, chargeable: create(:chargeable))
      @purchase_with_paid_balance.process!
      @purchase_with_paid_balance.mark_successful!
      @purchase_with_paid_balance.increment_sellers_balance!
      @purchase_with_paid_balance.purchase_success_balance.tap do |balance|
        balance.mark_processing!
        balance.mark_paid!
      end
      @user = @purchase.seller
    end

    it "does not refund purchases if the user is not suspended" do
      @user.mark_compliant!(author_id: @admin_user.id)
      described_class.new.perform(@user.id, @admin_user.id)
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase.id, @admin_user.id)
    end

    it "queues the refund of unpaid purchases" do
      @user.flag_for_fraud!(author_id: @admin_user.id)
      @user.suspend_for_fraud!(author_id: @admin_user.id)
      described_class.new.perform(@user.id, @admin_user.id)
      expect(RefundPurchaseWorker).to have_enqueued_sidekiq_job(@purchase.id, @admin_user.id)
      expect(@purchase.purchase_success_balance.unpaid?).to be(true)
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase_without_balance.id, @admin_user.id)
      expect(RefundPurchaseWorker).not_to have_enqueued_sidekiq_job(@purchase_with_paid_balance.id, @admin_user.id)
    end
  end
end
