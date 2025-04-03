# frozen_string_literal: true

require "spec_helper"
require "shared_examples/policy_examples"

describe CollaboratorInvitationPolicy do
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

  let(:collaborator_invitation_for_seller) do
    create(
      :collaborator_invitation,
      collaborator: create(:collaborator, affiliate_user: seller),
    )
  end

  let(:collaborator_invitation_for_another_seller) do
    create(
      :collaborator_invitation,
      collaborator: create(:collaborator, affiliate_user: create(:user)),
    )
  end

  let(:context_seller) { seller }

  permissions :accept?, :decline? do
    context "when the invitation is for the seller" do
      let(:record) { collaborator_invitation_for_seller }

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

    context "when the invitation is for another seller" do
      let(:record) { collaborator_invitation_for_another_seller }

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
