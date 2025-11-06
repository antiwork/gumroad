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

  context "when user is on probation due to LowBalanceFraudCheck" do
    before do
      user.put_on_probation(author_name: User::LowBalanceFraudCheck::LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME, content: "Test probation")
      user.disable_refunds!
    end

    it "removes probation and marks compliant when balance exceeds $100" do
      # Current balance is $99.99
      create(:balance, user: user, amount_cents: 99_99)
      expect { perform }.not_to change { user.reload.user_risk_state }

      # Current balance is $100
      create(:balance, user: user, amount_cents: 1)
      expect { perform }.not_to change { user.reload.user_risk_state }

      # Current balance is $100.01
      create(:balance, user: user, amount_cents: 1)
      expect { perform }.to change { user.reload.user_risk_state }.from("on_probation").to("compliant")
      expect(user.comments.last.author_name).to eq(User::LowBalanceFraudCheck::LOW_BALANCE_FRAUD_CHECK_AUTHOR_NAME)
    end

    it "also enables refunds when marking compliant" do
      create(:balance, user: user, amount_cents: 100_01)
      expect { perform }.to change { user.reload.refunds_disabled? }.from(true).to(false)
    end
  end

  context "when user is on probation for other reasons" do
    before do
      user.put_on_probation(author_name: "OtherReason", content: "Different probation reason")
    end

    it "does not remove probation even when balance exceeds $100" do
      create(:balance, user: user, amount_cents: 100_01)
      expect { perform }.not_to change { user.reload.user_risk_state }
    end
  end
end
