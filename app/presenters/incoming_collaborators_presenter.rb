# frozen_string_literal: true

class IncomingCollaboratorsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def index_props
    {
      collaborators: scoped_and_sorted_incoming_collaborators.map { CollaboratorPresenter.new(seller:).incoming_collaborator_props(_1) },
    }
  end

  private
    attr_reader :seller

    def scoped_and_sorted_incoming_collaborators
      Collaborator
        .alive
        .where(affiliate_user: seller)
        .left_joins(:collaborator_invitation)
        .includes(
          :collaborator_invitation,
          :seller,
          product_affiliates: :product
        )
        .order(
          Arel.sql("CASE WHEN collaborator_invitations.id IS NULL THEN 1 ELSE 0 END"),
          :id
        )
    end
end
