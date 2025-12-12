# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::PayoutsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:payment) { create(:payment_completed) }

  describe "GET show" do
    it "shows a payout" do
      sign_in admin_user
      get :show, params: { id: payment.id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Payouts/Show")
    end
  end

  describe "POST retry" do
    it "retries a failed payout" do
      failed_payment = create(:payment_failed)
      sign_in admin_user
      post :retry, params: { id: failed_payment.id }

      expect(response).to be_successful
    end
  end

  describe "POST cancel" do
    it "cancels an unclaimed paypal payout" do
      unclaimed_payment = create(:payment_unclaimed, processor: PayoutProcessorType::PAYPAL)
      sign_in admin_user
      post :cancel, params: { id: unclaimed_payment.id }

      expect(response).to be_successful
    end
  end

  describe "POST fail" do
    it "marks a processing payout as failed" do
      processing_payment = create(:payment, created_at: 3.days.ago)
      sign_in admin_user
      post :fail, params: { id: processing_payment.id }

      expect(response).to be_successful
    end
  end

  describe "POST sync" do
    it "syncs a paypal payout" do
      paypal_payment = create(:payment, processor: PayoutProcessorType::PAYPAL)
      sign_in admin_user
      post :sync, params: { id: paypal_payment.id }

      expect(response).to be_successful
    end
  end
end
