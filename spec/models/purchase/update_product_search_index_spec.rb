# frozen_string_literal: true

require "spec_helper"

describe Purchase do
  describe "#update_product_search_index!" do
    let(:purchase) { create(:purchase, price_cents: 0) }

    it "enqueues the search index update for the purchase's product" do
      expect(SendToElasticsearchWorker).to receive(:perform_in).with(
        5.seconds,
        purchase.link_id,
        "update",
        %w[is_recommendable sales_volume total_fee_cents past_year_fee_cents]
      )

      purchase.send(:update_product_search_index!)
    end

    # The enqueue runs in the state machine's after_transition, inside the transaction that follows
    # a successful charge. An escaping Redis error there rolls back a purchase the processor
    # already charged, and surfaces as a checkout 500.
    [Redis::CannotConnectError, RedisClient::ReadTimeoutError].each do |error_class|
      context "when the enqueue raises #{error_class}" do
        before do
          allow(SendToElasticsearchWorker).to receive(:perform_in)
            .and_raise(error_class, "Waited 3 seconds")
        end

        it "reports the failure instead of raising" do
          expect(ErrorNotifier).to receive(:notify).with(
            instance_of(error_class),
            purchase_id: purchase.id,
            link_id: purchase.link_id,
            product_search_index_enqueue_failed: true
          )

          expect { purchase.send(:update_product_search_index!) }.not_to raise_error
        end

        it "does not raise when the failure report itself fails" do
          allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "notifier down")

          expect { purchase.send(:update_product_search_index!) }.not_to raise_error
        end
      end
    end

    it "still raises non-Redis enqueue errors so real bugs are not hidden" do
      allow(SendToElasticsearchWorker).to receive(:perform_in).and_raise(NoMethodError, "boom")

      expect { purchase.send(:update_product_search_index!) }.to raise_error(NoMethodError)
    end

    describe "through the paid purchase's success transition" do
      let(:purchase) { create(:purchase, purchase_state: "in_progress") }
      let(:timeout_error) { RedisClient::ReadTimeoutError.new("Waited 3 seconds") }

      before do
        allow(SendToElasticsearchWorker).to receive(:perform_in).and_raise(timeout_error)
      end

      it "persists the successful purchase and reports the failure" do
        expect(purchase.price_cents).to be > 0
        expect(ErrorNotifier).to receive(:notify).with(timeout_error, purchase_id: purchase.id, link_id: purchase.link_id, product_search_index_enqueue_failed: true)

        purchase.update_balance_and_mark_successful!

        expect(purchase.reload.purchase_state).to eq("successful")
      end

      it "persists the successful purchase when reporting the failure also fails" do
        allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "notifier down")

        purchase.update_balance_and_mark_successful!

        expect(purchase.reload.purchase_state).to eq("successful")
      end
    end
  end
end
