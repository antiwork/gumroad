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
  end
end
