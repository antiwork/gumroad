# frozen_string_literal: true

require "spec_helper"

describe User::VipCreator do
  let(:user) { create(:user) }

  describe "#vip_creator?" do
    context "when gross completed payouts exceed the threshold" do
      it "returns true" do
        create(:payment_completed, user:, amount_cents: 3_000_00)
        create(:payment_completed, user:, amount_cents: 2_500_00)

        expect(user.vip_creator?).to be true
      end
    end

    context "when gross completed payouts are at or below the threshold" do
      it "returns false when the user has no payments" do
        expect(user.payments).to be_empty
        expect(user.vip_creator?).to be false
      end

      it "returns false at exactly the threshold" do
        create(:payment_completed, user:, amount_cents: 5_000_00)

        expect(user.vip_creator?).to be false
      end

      it "ignores non-completed payouts" do
        create(:payment, user:, amount_cents: 10_000_00)

        expect(user.vip_creator?).to be false
      end
    end
  end
end
