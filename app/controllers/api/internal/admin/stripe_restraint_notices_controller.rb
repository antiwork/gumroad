# frozen_string_literal: true

# Admin API surface for Stripe court-order ("restraint") notices, so the mail-side automation can
# notify the seller by Stripe account id instead of a human rebuilding the lookup in a console
# (gumroad-private#3598). Telling a seller about a court order is a real outbound mail, so it needs
# an attributable actor, and it defaults to a dry run.
class Api::Internal::Admin::StripeRestraintNoticesController < Api::Internal::Admin::BaseController
  before_action :require_per_actor_token!, only: :create
  before_action :fetch_user_for_write, only: :create

  def create
    dry_run = params[:dry_run].to_s.strip.downcase.then { |value| !%w[false 0 f off no].include?(value) }

    record_admin_write(action: "stripe_restraint_notices.create", target: @user) do
      result = StripeRestraintNoticeService.call(
        stripe_account_id: params[:stripe_account_id],
        firm_name: params[:firm_name],
        firm_email: params[:firm_email],
        notice_key: params[:notice_key],
        dry_run:,
      )

      render json: { success: true, dry_run: }.merge(result.to_h)
    end
  rescue StripeRestraintNoticeService::InvalidNoticeError => e
    render json: { success: false, message: e.message }, status: :bad_request
  rescue User::CreateAdminCommentService::IdempotencyConflictError => e
    render json: { success: false, message: e.message }, status: :conflict
  end

  private
    def fetch_user_for_write
      @user = StripeRestraintNoticeService.resolve_user!(params[:stripe_account_id])
    rescue StripeRestraintNoticeService::InvalidNoticeError => e
      render json: { success: false, message: e.message }, status: :bad_request
    rescue StripeRestraintNoticeService::UserNotFoundError => e
      render json: { success: false, message: e.message }, status: :not_found
    rescue StripeRestraintNoticeService::AmbiguousUserError => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
end
