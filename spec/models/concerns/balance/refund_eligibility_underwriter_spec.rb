# frozen_string_literal: true

require "spec_helper"

describe Balance::RefundEligibilityUnderwriter do
  describe "#update_seller_refund_eligibility" do
    let(:user) { create(:user) }

    # Eagerly create this so `expect` block doesn't enqueue any jobs due to creating this.
    let!(:balance) { create(:balance, user: user, amount_cents: 1000) }

    context "when user_id is blank" do
      before do
        balance.user_id = nil
      end

      it "does not enqueue the job" do
        expect { balance.update!(holding_amount_cents: 5000) }.not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
      end
    end

    context "when amount_cents changes" do
      context "when balance increases and refunds are disabled" do
        before { user.disable_refunds! }

        it "enqueues the job" do
          expect { balance.update!(amount_cents: 2000) }
            .to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(user.id)
        end
      end

      context "when balance increases and refunds are enabled" do
        before { user.enable_refunds! }

        it "does not enqueue the job" do
          expect { balance.update!(amount_cents: 2000) }
            .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
        end
      end

      context "when balance decreases and refunds are disabled" do
        before { user.disable_refunds! }

        it "does not enqueue the job" do
          expect { balance.update!(amount_cents: 500) }
            .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
        end
      end

      context "when balance decreases and refunds are enabled" do
        before { user.enable_refunds! }

        it "enqueues the job" do
          expect { balance.update!(amount_cents: 500) }
            .to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(user.id)
        end
      end
    end

    context "when amount_cents does not change" do
      it "does not enqueue the job" do
        expect { balance.mark_processing! }
          .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
      end
    end
  end
end
