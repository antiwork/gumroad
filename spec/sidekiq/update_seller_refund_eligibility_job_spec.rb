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
end
