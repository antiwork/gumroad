# frozen_string_literal: true

require "spec_helper"

describe Admin::Impersonators::UserPolicy do
  subject { described_class }

  let(:user) { create(:user) }
  let(:admin_user) { create(:admin_user) }
  let(:seller_context) { SellerContext.new(user: admin_user, seller: admin_user) }

  permissions :create? do
    context "when record is a regular user" do
      it "grants access" do
        expect(subject).to permit(seller_context, user)
      end
    end

    context "when user is deleted" do
      let(:user) { create(:user, :deleted) }

      it "denies access with message" do
        expect(subject).not_to permit(seller_context, user)
      end
    end

    context "when user is a team member" do
      it "denies access" do
        expect(subject).not_to permit(seller_context, admin_user)
      end
    end
  end
end
