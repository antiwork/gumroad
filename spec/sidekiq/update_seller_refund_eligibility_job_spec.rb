# frozen_string_literal: true

require "spec_helper"

describe UpdateSellerRefundEligibilityJob do
  let(:user) { create(:user) }

  def perform
    described_class.new.perform(user.id)
  end

  context "when refund is currently disabled" do
    before { user.disable_refunds! }

    it "enables refunds when balance goes above $0" do
      # Current balance is -100.01
      create(:balance, user: user, amount_cents: -100_01)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is -100
      create(:balance, user: user, amount_cents: 1)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is 0
      create(:balance, user: user, amount_cents: 100_00)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is $0.01
      create(:balance, user: user, amount_cents: 1)
      expect { perform }.to change { user.reload.refunds_disabled? }.from(true).to(false)
    end
  end

  context "when refund is currently enabled" do
    before { user.enable_refunds! }

    it "disables refunds when balance dips below -$100" do
      # Current balance is 0.01
      create(:balance, user: user, amount_cents: 1)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is 0
      create(:balance, user: user, amount_cents: -1)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is -100
      create(:balance, user: user, amount_cents: -100_00)
      expect { perform }.not_to change { user.reload.refunds_disabled? }

      # Current balance is -100.01
      create(:balance, user: user, amount_cents: -1)
      expect { perform }.to change { user.reload.refunds_disabled? }.from(false).to(true)
    end
  end

  context "when checking if user can recover from low balance probation" do
    with_versioning do
      before do
        user.send(:disable_refunds_and_put_on_probation!)
      end

      it "does not recover when balance is below $100" do
        create(:balance, user: user, amount_cents: 99_99)
        expect { perform }.not_to change { user.reload.user_risk_state }
      end

      it "enables refunds and restores risk state when balance is at or above $100" do
        expect_any_instance_of(User).to receive(:can_recover_from_low_balance_probation?).with(100_00).and_call_original
        expect_any_instance_of(User).to receive(:restore_user_risk_state_before_probation!).and_call_original

        create(:balance, user: user, amount_cents: 100_00)

        expect { perform }
          .to change { user.reload.user_risk_state }.from("on_probation").to("not_reviewed")
          .and change { user.reload.refunds_disabled? }.from(true).to(false)
      end
    end
  end

  describe "sidekiq_retry_in" do
    it "returns :discard, logs, and notifies Bugsnag for InvalidRecoveryStateError" do
      error_message = "Invalid previous state for recovery: suspended_for_fraud"
      exception = User::LowBalanceFraudCheck::InvalidRecoveryStateError.new(error_message)

      expect(Rails.logger).to receive(:error)
        .with("[UpdateSellerRefundEligibilityJob] Discarding job on 1st attempt for invalid recovery state: #{error_message}")

      expect(Bugsnag).to receive(:notify).with(exception)

      result = described_class::RetryHandler.call(0, exception, {})
      expect(result).to eq(:discard)
    end

    it "returns nil for other exceptions to allow normal retry" do
      other_exception = StandardError.new("Some error")
      result = described_class::RetryHandler.call(0, other_exception, {})
      expect(result).to be_nil
    end
  end
end
