# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Compliance::CardsController do
  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "POST refund" do
    context "when stripe_fingerprint is blank" do
      it "returns an error" do
        post :refund
        expect(response.parsed_body["success"]).to eq(false)
      end
    end

    context "when stripe_fingerprint is not blank" do
      let(:stripe_fingerprint) { "FakeFingerprint" }
      let!(:successful_purchase) { create(:purchase, stripe_fingerprint:, purchase_state: "successful") }
      let!(:failed_purchase) { create(:purchase, stripe_fingerprint:, purchase_state: "failed") }
      let!(:disputed_purchase) { create(:purchase, stripe_fingerprint:, chargeback_date: Time.current) }
      let!(:refunded_purchase) { create(:refunded_purchase, stripe_fingerprint:) }

      it "enqueues jobs" do
        post :refund, params: { stripe_fingerprint: }

        expect(RefundPurchaseWorker.jobs.size).to eq(1)
        expect(RefundPurchaseWorker).to have_enqueued_sidekiq_job(successful_purchase.id, @admin_user.id, Refund::FRAUD)

        expect(response.parsed_body["success"]).to eq(true)
      end

      it "only refunds purchases from the last 6 months" do
        create(:purchase, stripe_fingerprint:, created_at: 7.months.ago)
        recent_purchase = create(:purchase, stripe_fingerprint:, created_at: 5.months.ago)

        post :refund, params: { stripe_fingerprint: }

        expect(RefundPurchaseWorker.jobs.size).to eq(2)
        expect(RefundPurchaseWorker).to have_enqueued_sidekiq_job(successful_purchase.id, @admin_user.id, Refund::FRAUD)
        expect(RefundPurchaseWorker).to have_enqueued_sidekiq_job(recent_purchase.id, @admin_user.id, Refund::FRAUD)
      end
    end
  end
end
