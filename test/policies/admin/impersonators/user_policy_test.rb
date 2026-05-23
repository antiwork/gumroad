# frozen_string_literal: true

require "test_helper"

class AdminImpersonatorsUserPolicyTest < ActiveSupport::TestCase
  self.described_class = Admin::Impersonators::UserPolicy



  context_ Admin::Impersonators::UserPolicy do
    subject { described_class }

    let(:user) { create(:user) }
    let(:admin_user) { create(:admin_user) }
    let(:seller_context) { SellerContext.new(user: admin_user, seller: admin_user) }

    permissions :create? do
  context_ "when record is a regular user" do
  test "grants access" do
          expect(subject).to permit(seller_context, user)
        end
      end

  context_ "when user is deleted" do
        let(:user) { create(:user, :deleted) }

  test "denies access with message" do
          expect(subject).not_to permit(seller_context, user)
        end
      end

  context_ "when user is a team member" do
  test "denies access" do
          expect(subject).not_to permit(seller_context, admin_user)
        end
      end
    end
  end
end
