# frozen_string_literal: true

class CollaboratorsPresenter
  def initialize(seller:)
    @seller = seller
  end

  def index_props
    {
      collaborators: @seller.collaborators.alive.includes(:collaborator_invitation, product_affiliates: :product, affiliate_user: { avatar_attachment: :blob }).map { CollaboratorPresenter.new(seller: @seller, collaborator: _1).collaborator_props },
      has_incoming_collaborators: @seller.incoming_collaborators.alive.exists?,
    }
  end
end
