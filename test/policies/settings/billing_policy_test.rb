# frozen_string_literal: true

require "test_helper"

class SettingsBillingPolicyTest < ActiveSupport::TestCase
  self.described_class = Settings::BillingPolicy



  context_ Settings::BillingPolicy do
    subject { described_class }

    let(:owner) { create(:user) }
    let(:other_user) { create(:user) }

    permissions :show?, :update? do
  test "grants access when the viewer is the seller themselves" do
  context_ = SellerContext.new(user: owner, seller: owner)
        expect(subject).to permit(context, nil)
      end

  test "denies access when the viewer is a different user on the seller account" do
  context_ = SellerContext.new(user: other_user, seller: owner)
        expect(subject).not_to permit(context, nil)
      end
    end
  end
end
