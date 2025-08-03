# frozen_string_literal: true

class Api::Internal::Affiliates::InvitationDeclinesController < Api::Internal::BaseController
  before_action :authenticate_user!

  before_action :set_affiliate!
  before_action :set_invitation!

  after_action :verify_authorized

  def create
    authorize @invitation, :decline?

    @invitation.decline!

    head :ok
  end

  private
    def set_affiliate!
      @affiliate = DirectAffiliate.alive.find_by_external_id!(params[:affiliate_id])
    end

    def set_invitation!
      @invitation = @affiliate.affiliate_invitation || e404
    end
end
