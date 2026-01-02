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

  context "when user is on LowBalanceFraudCheck probation" do
    before do
      user.send(:disable_refunds_and_put_on_probation!)
      user.reload
    end

    it "removes probation when balance exceeds $100" do
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(101_00)

      expect { perform }.to change { user.reload.on_probation? }.from(true).to(false)
      expect(user.refunds_disabled?).to eq(false)
    end

    it "does not remove probation when balance is $100 or below" do
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)

      expect { perform }.not_to change { user.reload.on_probation? }
    end

    it "reverts to original risk state (not_reviewed)" do
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(101_00)

      perform

      expect(user.reload.user_risk_state).to eq("not_reviewed")
    end
  end

  context "when user is manually probated by admin" do
    before do
      user.put_on_probation(author_name: "admin", content: "manual probation")
      allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(101_00)
    end

    it "does not remove probation even when balance exceeds $100" do
      expect { perform }.not_to change { user.reload.on_probation? }
    end
  end
end
