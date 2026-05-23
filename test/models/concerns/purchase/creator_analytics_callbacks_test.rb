# frozen_string_literal: true

require "test_helper"

class PurchaseCreatorAnalyticsCallbacksTest < ActiveSupport::TestCase
  self.described_class = Purchase::CreatorAnalyticsCallbacks



  context_ Purchase::CreatorAnalyticsCallbacks do
  context_ "when the purchase happened today" do
  test "does not queue job after update" do
        purchase = create(:purchase_in_progress)
        purchase.mark_successful!

        expect(RegenerateCreatorAnalyticsCacheWorker.jobs.size).to eq(0)
      end

  test "does not queue job after refunding" do
        purchase = create(:purchase)
        purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller)

        expect(RegenerateCreatorAnalyticsCacheWorker.jobs.size).to eq(0)
      end
    end

  context_ "when the purchase happened before today" do
      before do
        travel_to(Time.utc(2020, 1, 10))
      end

  test "queues job after update" do
        purchase = create(:purchase_in_progress, created_at: 2.days.ago)
        purchase.mark_successful!

        expect(RegenerateCreatorAnalyticsCacheWorker).to have_enqueued_sidekiq_job(purchase.seller_id, "2020-01-07")
      end

  test "queues the job after refunding" do
        purchase = create(:purchase, created_at: 2.days.ago)
        purchase.refund_purchase!(FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents), purchase.seller)

        expect(RegenerateCreatorAnalyticsCacheWorker).to have_enqueued_sidekiq_job(purchase.seller_id, "2020-01-07")
      end
    end
  end
end
