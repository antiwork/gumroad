# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe CollaboratorPolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }

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

  let(:context_seller) { seller }

  let(:collaboration_initiated_by_seller) { create(:collaborator, seller:) }
  let(:collaboration_adding_seller) { create(:collaborator, affiliate_user: seller) }
  let(:collaboration_between_other_people) { create(:collaborator) }

  permissions :index?, :new?, :create? do
    let(:record) { Collaborator }

    it_behaves_like "an access-granting policy for roles", [
      :seller,
      :admin_for_seller,
    ]

    it_behaves_like "an access-denying policy for roles", [
      :accountant_for_seller,
      :marketing_for_seller,
      :support_for_seller,
    ]
  end

  permissions :edit?, :update? do
    context "collaboration initiated by seller" do
      let(:record) { collaboration_initiated_by_seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
      ]

      it_behaves_like "an access-denying policy for roles", [
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end

    context "collaboration adding seller" do
      let(:record) { collaboration_adding_seller }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end

    context "collaboration between other people" do
      let(:record) { collaboration_between_other_people }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end
  end

  permissions :destroy? do
    context "collaboration initiated by seller" do
      let(:record) { collaboration_initiated_by_seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
      ]

      it_behaves_like "an access-denying policy for roles", [
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end

    context "collaboration adding seller" do
      let(:record) { collaboration_adding_seller }

      it_behaves_like "an access-granting policy for roles", [
        :seller,
        :admin_for_seller,
      ]

      it_behaves_like "an access-denying policy for roles", [
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end

    context "collaboration between other people" do
      let(:record) { collaboration_between_other_people }

      it_behaves_like "an access-denying policy for roles", [
        :seller,
        :admin_for_seller,
        :accountant_for_seller,
        :marketing_for_seller,
        :support_for_seller,
      ]
    end
  end
end
