# frozen_string_literal: true

require "test_helper"

class BalanceRefundEligibilityUnderwriterTest < ActiveSupport::TestCase
  self.described_class = Balance::RefundEligibilityUnderwriter



  context_ Balance::RefundEligibilityUnderwriter do
  context_ "#update_seller_refund_eligibility" do
      let(:user) { create(:user) }

      # Eagerly create this so `expect` block doesn't enqueue any jobs due to creating this.
      let!(:balance) { create(:balance, user: user, amount_cents: 1000) }

  context_ "when user_id is blank" do
        before do
          balance.user_id = nil
        end

  test "does not enqueue the job" do
          expect { balance.update!(holding_amount_cents: 5000) }.not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
        end
      end

  context_ "when amount_cents changes" do
  context_ "when balance increases and refunds are disabled" do
          before { user.disable_refunds! }

  test "enqueues the job" do
            expect { balance.update!(amount_cents: 2000) }
              .to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(user.id)
          end
        end

  context_ "when balance increases and refunds are enabled" do
          before { user.enable_refunds! }

  test "does not enqueue the job" do
            expect { balance.update!(amount_cents: 2000) }
              .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
          end
        end

  context_ "when balance decreases and refunds are disabled" do
          before { user.disable_refunds! }

  test "does not enqueue the job" do
            expect { balance.update!(amount_cents: 500) }
              .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
          end
        end

  context_ "when balance decreases and refunds are enabled" do
          before { user.enable_refunds! }

  test "enqueues the job" do
            expect { balance.update!(amount_cents: 500) }
              .to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(user.id)
          end
        end
      end

  context_ "when amount_cents does not change" do
  test "does not enqueue the job" do
          expect { balance.mark_processing! }
            .not_to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob)
        end
      end
    end
  end
end
