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

      context "when balance increases, refunds are enabled and the user is on probation" do
        before do
          user.enable_refunds!
          user.put_on_probation!(author_name: "LowBalanceFraudCheck", content: "probated")
        end

        it "enqueues the job" do
          expect { balance.update!(amount_cents: 2000) }
            .to enqueue_sidekiq_job(UpdateSellerRefundEligibilityJob).with(user.id)
        end
      end

      context "when a LowBalanceFraudCheck probation outlives refunds being re-enabled below $100", versioning: true do
        before do
          user.send(:disable_refunds_and_put_on_probation!)
          balance.update!(amount_cents: 50_00)
          UpdateSellerRefundEligibilityJob.drain
        end

        it "lifts the probation once later increases bring the balance to $100" do
          expect(user.reload.refunds_disabled?).to be(false)

          balance.update!(amount_cents: 99_99)
          UpdateSellerRefundEligibilityJob.drain
          expect(user.reload).to be_on_probation

          balance.update!(amount_cents: 100_00)
          UpdateSellerRefundEligibilityJob.drain
          expect(user.reload.user_risk_state).to eq("not_reviewed")
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
