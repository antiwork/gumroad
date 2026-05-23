# frozen_string_literal: true

require "test_helper"

class UserVipCreatorTest < ActiveSupport::TestCase
  self.described_class = User::VipCreator



  context_ User::VipCreator do
    let(:user) { create(:user) }

  context_ "#vip_creator?" do
  context_ "when gross completed payouts exceed the threshold" do
  test "returns true" do
          create(:payment_completed, user:, amount_cents: 3_000_00)
          create(:payment_completed, user:, amount_cents: 2_500_00)

          expect(user.vip_creator?).to be true
        end
      end

  context_ "when gross completed payouts are at or below the threshold" do
  test "returns false when the user has no payments" do
          expect(user.payments).to be_empty
          expect(user.vip_creator?).to be false
        end

  test "returns false at exactly the threshold" do
          create(:payment_completed, user:, amount_cents: 5_000_00)

          expect(user.vip_creator?).to be false
        end

  test "ignores non-completed payouts" do
          create(:payment, user:, amount_cents: 10_000_00)

          expect(user.vip_creator?).to be false
        end
      end
    end
  end
end
