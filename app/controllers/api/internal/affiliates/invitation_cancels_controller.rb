# frozen_string_literal: true

class Api::Internal::Affiliates::InvitationCancelsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_affiliate!
  before_action :set_invitation!
  after_action :verify_authorized

  def create
    authorize @invitation, :cancel?

    @invitation.destroy!
    @affiliate.mark_deleted!

    head :ok
  end

  private
    def set_affiliate!
      @affiliate = current_seller.direct_affiliates.alive.find_by_external_id!(params[:affiliate_id])
    end

    def set_invitation!
      @invitation = @affiliate.affiliate_invitation || e404
    end
end
