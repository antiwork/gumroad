# frozen_string_literal: true

class Collaborators::BaseController < Sellers::BaseController
  before_action :authorize_user

  layout "inertia"

  inertia_share { CollaboratorPresenter.new(seller: current_seller).inertia_shared_props }

  def destroy
    raise NotImplementedError, "Subclasses must implement destroy" unless block_given?

    @collaborator.mark_deleted!

    if current_seller == @collaborator.seller
      AffiliateMailer.collaboration_ended_by_seller(@collaborator.id).deliver_later
    elsif current_seller == @collaborator.affiliate_user
      AffiliateMailer.collaboration_ended_by_affiliate_user(@collaborator.id).deliver_later
    end

    yield
  end

  private
    def set_collaborator
      @collaborator = Collaborator.alive.find_by_external_id(params[:id]) || e404
    end

    def authorize_user
      if @collaborator.present?
        authorize @collaborator
      else
        authorize Collaborator
      end
    end

    def set_title
      @title = "Collaborators"
    end
end
