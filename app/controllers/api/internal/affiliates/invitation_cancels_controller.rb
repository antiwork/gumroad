# frozen_string_literal: true

class Api::Internal::Affiliates::InvitationCancelsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_affiliate!
  before_action :set_invitation!
  after_action :verify_authorized

  def create
    authorize @invitation, :cancel?

    ActiveRecord::Base.transaction do
      @invitation.with_lock do
        @invitation.reload
        if @invitation.respond_to?(:pending?) && !@invitation.pending?
          raise ActiveRecord::RecordInvalid.new(@invitation)
        end
        @invitation.destroy!
        @affiliate.mark_deleted!
      end
    end
    head :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private
    def set_affiliate!
      @affiliate = DirectAffiliate.alive.find_by_external_id!(params[:affiliate_id])
    end

    def set_invitation!
      @invitation = @affiliate.affiliate_invitation || e404
    end
end
