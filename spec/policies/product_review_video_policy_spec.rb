# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe ProductReviewVideoPolicy do
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
  let(:purchase) { create(:purchase, link: product, seller: seller) }
  let(:product_review) { create(:product_review, purchase: purchase) }
  let(:product_review_video_for_seller) do
    create(
      :product_review_video,
      product_review: product_review,
      approval_status: :pending_review
    )
  end

  let(:product_review_video_for_another_seller) do
    another_seller = create(:user)
    another_product = create(:product, user: another_seller)
    another_purchase = create(:purchase, link: another_product, seller: another_seller)
    another_product_review = create(:product_review, purchase: another_purchase)

    create(
      :product_review_video,
      product_review: another_product_review,
      approval_status: :pending_review
    )
  end

  let(:context_seller) { seller }

  permissions :approve?, :reject? do
    context "when the video is for the seller's product review" do
      let(:record) { product_review_video_for_seller }

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

    context "when the video is for another seller's product review" do
      let(:record) { product_review_video_for_another_seller }

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
