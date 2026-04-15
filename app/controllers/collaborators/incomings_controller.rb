# frozen_string_literal: true

class Collaborators::IncomingsController < Collaborators::BaseController
  skip_before_action :authorize_user, only: [:accept, :decline]
  prepend_before_action :set_collaborator, only: [:accept, :decline, :destroy]
  before_action :set_invitation!, only: [:accept, :decline]

  def index
    render inertia: "Collaborators/Incomings/Index", props: IncomingCollaboratorsPresenter.new(seller: current_seller).index_props
  end

  def accept
    authorize @invitation, :accept?

    @invitation.accept!

    redirect_to collaborators_incomings_path, status: :see_other, notice: "Invitation accepted"
  end

  def decline
    authorize @invitation, :decline?

    @invitation.decline!

    redirect_to collaborators_incomings_path, status: :see_other, notice: "Invitation declined"
  end

  def destroy
    super do
      redirect_to collaborators_incomings_path, status: :see_other, notice: "Collaborator removed"
    end
  end

  private
    def set_invitation!
      @invitation = @collaborator.collaborator_invitation || e404
    end
end
