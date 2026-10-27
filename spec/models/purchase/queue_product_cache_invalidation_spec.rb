# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#queue_product_cache_invalidation" do
    let(:purchase) { create(:purchase) }

    it "enqueues the cache invalidation for the purchase's product" do
      expect(InvalidateProductCacheWorker).to receive(:perform_in).with(1.minute, purchase.link_id)

      purchase.send(:queue_product_cache_invalidation)
    end

    # gp#3948 / gp#3947: the enqueue runs in the state-machine after_transition, inside the
    # transaction that follows a successful charge. An escaping Redis error there rolls back
    # a purchase the processor already charged, and surfaced as a checkout 500.
    [
      Redis::CannotConnectError,
      RedisClient::CannotConnectError,
    ].each do |error_class|
      context "when the enqueue raises #{error_class}" do
        before do
          allow(InvalidateProductCacheWorker).to receive(:perform_in)
            .and_raise(error_class, "READONLY You can't write against a read only replica.")
        end

        it "reports the failure instead of raising" do
          expect(ErrorNotifier).to receive(:notify).with(
            instance_of(error_class),
            purchase_id: purchase.id,
            link_id: purchase.link_id,
            cache_invalidation_enqueue_failed: true
          )

          expect { purchase.send(:queue_product_cache_invalidation) }.not_to raise_error
        end

        it "does not raise when the failure report itself fails" do
          allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "notifier down")

          expect { purchase.send(:queue_product_cache_invalidation) }.not_to raise_error
        end
      end
    end

    it "still raises non-Redis errors so real bugs are not hidden" do
      allow(InvalidateProductCacheWorker).to receive(:perform_in).and_raise(NoMethodError)

      expect { purchase.send(:queue_product_cache_invalidation) }.to raise_error(NoMethodError)
    end

    describe "through the paid purchase's success transition" do
      let(:purchase) { create(:purchase, purchase_state: "in_progress") }
      let(:readonly_error) { RedisClient::ReadOnlyError.new("READONLY You can't write against a read only replica.") }

      it "persists the successful purchase and runs the later transition callbacks" do
        allow(InvalidateProductCacheWorker).to receive(:perform_in).and_raise(readonly_error)
        expect(ErrorNotifier).to receive(:notify).with(readonly_error, purchase_id: purchase.id, link_id: purchase.link_id, cache_invalidation_enqueue_failed: true)

        purchase.update_balance_and_mark_successful!

        expect(purchase.reload.purchase_state).to eq("successful")
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(purchase.link_id, "update", %w[is_recommendable sales_volume total_fee_cents past_year_fee_cents])
      end

      it "persists the successful purchase when reporting the failure also fails" do
        allow(InvalidateProductCacheWorker).to receive(:perform_in).and_raise(readonly_error)
        allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "notifier down")

        purchase.update_balance_and_mark_successful!

        expect(purchase.reload.purchase_state).to eq("successful")
      end
    end
  end
end
