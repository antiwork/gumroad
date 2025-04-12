# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe S3UtilityPolicy do
  subject { described_class }

  let(:buyer) { create(:user) }
  let(:seller) { create(:named_seller) }

  let(:admin_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_ADMIN,
    ).user
  end

  let(:support_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_SUPPORT,
    ).user
  end

  let(:accountant_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_ACCOUNTANT,
    ).user
  end

  let(:marketing_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_MARKETING,
    ).user
  end

  let(:record) { S3UtilityPolicy }

  permissions :generate_multipart_signature?, :current_utc_time_string?, :cdn_url_for_blob? do
    context "in a seller context" do
      let(:context_seller) { seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
        :marketing_for_seller,
        :accountant_for_seller,
        :support_for_seller
      ]
    end

    context "in a non-seller context" do
      let(:context_seller) { nil }

      it_behaves_like "an access-granting policy for roles", [:buyer]
    end

    context "anonymous user" do
      it "denies access" do
        expect do
          expect(subject).not_to permit(SellerContext.logged_out, record)
        end.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
      end
    end
  end
end
