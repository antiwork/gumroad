# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe ProductReviewResponsePolicy do
  subject { described_class }

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

  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller:) }
  let(:product_review) { create(:product_review, purchase:) }
  let(:product_review_response_for_seller) do
    create(:product_review_response, product_review: product_review)
  end

  let(:product_review_response_for_another_seller) { create(:product_review_response) }

  let(:context_seller) { seller }

  permissions :update? do
    context "when the response is for the seller's product review" do
      let(:record) { product_review_response_for_seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
        :support_for_seller,
      ]

      it_behaves_like "an access-denying policy for roles", [
        :accountant_for_seller,
        :marketing_for_seller,
      ]
    end

    context "when the response is for another seller's product review" do
      let(:record) { product_review_response_for_another_seller }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :support_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
      ]
    end
  end

  permissions :destroy? do
    context "when the response is for the seller's product review" do
      let(:record) { product_review_response_for_seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
        :support_for_seller,
      ]

      it_behaves_like "an access-denying policy for roles", [
        :accountant_for_seller,
        :marketing_for_seller,
      ]
    end

    context "when the response is for another seller's product review" do
      let(:record) { product_review_response_for_another_seller }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :support_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
      ]
    end
  end
end
