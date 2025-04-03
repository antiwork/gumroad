# frozen_string_literal: true

class Api::Internal::Collaborators::InvitationAcceptancesController < Api::Internal::BaseController
  before_action :authenticate_user!

  before_action :set_collaborator!
  before_action :set_invitation!

  after_action :verify_authorized

  def create
    authorize @invitation, :accept?

    @invitation.accept!

    head :ok
  end

  private
    def set_collaborator!
      @collaborator = Collaborator.alive.find_by_external_id!(params[:collaborator_id])
    end

    def set_invitation!
      @invitation = @collaborator.collaborator_invitation || e404
    end
end
