# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe GumroadBlog::PostsPolicy do
  subject { described_class }

  let(:seller) { create(:user) }
  let(:another_seller) { create(:user) }

  let(:admin_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_ADMIN,
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

  let(:support_for_seller) do
    create(
      :team_membership,
      seller: seller,
      role: TeamMembership::ROLE_SUPPORT,
    ).user
  end

  let(:published_post) do
    create(
      :audience_post,
      :published,
      seller: seller,
      deleted_at: nil,
      shown_on_profile: true,
      workflow_id: nil
    )
  end

  let(:unpublished_post) do
    create(
      :audience_post,
      seller: seller,
      published_at: nil,
      deleted_at: nil,
      shown_on_profile: true,
      workflow_id: nil
    )
  end

  let(:dead_post) do
    create(
      :audience_post,
      :published,
      seller: seller,
      deleted_at: Time.current,
      shown_on_profile: true,
      workflow_id: nil
    )
  end

  let(:hidden_post) do
    create(
      :audience_post,
      :published,
      seller: seller,
      deleted_at: nil,
      shown_on_profile: false,
      workflow_id: nil
    )
  end

  let(:workflow_post) do
    create(
      :audience_post,
      :published,
      seller: seller,
      deleted_at: nil,
      shown_on_profile: true,
      workflow_id: "some_workflow_id"
    )
  end

  let(:no_audience_post) do
    create(
      :post,
      :published,
      seller: seller,
      deleted_at: nil,
      shown_on_profile: true,
      workflow_id: nil
    )
  end

  let(:another_seller_post) do
    create(
      :audience_post,
      :published,
      seller: another_seller,
      deleted_at: nil,
      shown_on_profile: true,
      workflow_id: nil
    )
  end

  let(:context_seller) { seller }

  permissions :index? do
    let(:record) { published_post }

    it_behaves_like "an access-granting policy for roles", [
      :seller,
      :admin_for_seller,
      :accountant_for_seller,
      :marketing_for_seller,
      :support_for_seller,
    ]

    it "grants access to anonymous users" do
      expect(subject).to permit(SellerContext.logged_out, record)
    end
  end

  permissions :show? do
    context "when the post is published and meets all criteria" do
      let(:record) { published_post }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      it "grants access to anonymous users" do
        expect(subject).to permit(SellerContext.logged_out, record)
      end
    end

    context "when the post is unpublished" do
      let(:record) { unpublished_post }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      context "for another seller" do
        let(:context_seller) { another_seller }

        it_behaves_like "an access-denying policy for roles", [
          :another_seller,
        ]
      end

      it "denies access to anonymous users" do
        expect(subject).not_to permit(SellerContext.logged_out, record)
      end
    end

    context "when the post is not alive" do
      let(:record) { dead_post }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      it "denies access to anonymous users" do
        expect(subject).not_to permit(SellerContext.logged_out, record)
      end
    end

    context "when the post is not shown on profile" do
      let(:record) { hidden_post }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      it "denies access to anonymous users" do
        expect(subject).not_to permit(SellerContext.logged_out, record)
      end
    end

    context "when the post is a workflow post" do
      let(:record) { workflow_post }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      it "denies access to anonymous users" do
        expect(subject).not_to permit(SellerContext.logged_out, record)
      end
    end

    context "when the post is not an audience post" do
      let(:record) { no_audience_post }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]

      it "denies access to anonymous users" do
        expect(subject).not_to permit(SellerContext.logged_out, record)
      end
    end
  end
end
