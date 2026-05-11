# frozen_string_literal: true

class Api::Internal::Admin::ScheduledPayoutsController < Api::Internal::Admin::BaseController
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 50
  private_constant :DEFAULT_LIMIT, :MAX_LIMIT

  before_action :fetch_scheduled_payout, only: [:execute, :cancel]

  def index
    scope = ScheduledPayout.includes(:user, :created_by).order(id: :desc)

    if params[:user_id].present? || params[:external_id].present? || params[:email].present?
      user = find_internal_admin_user_for_read_or_render
      return unless user
      scope = scope.for_user(user)
    end

    statuses = Array.wrap(params[:status]).reject(&:blank?)
    if statuses.any?
      invalid = statuses - ScheduledPayout::STATUSES
      if invalid.any?
        return render json: { success: false, message: "status is invalid" }, status: :bad_request
      end
      scope = scope.where(status: statuses)
    end

    limit = params[:limit].to_i
    limit = DEFAULT_LIMIT if limit <= 0
    limit = [limit, MAX_LIMIT].min

    records = scope.limit(limit).to_a
    enrichment_by_user_id = Admin::ScheduledPayoutEnrichmentService.new(records).call
    scheduled_payouts = records.map { serialize_scheduled_payout(_1, enrichment: enrichment_by_user_id[_1.user_id] || {}) }

    render json: { success: true, scheduled_payouts:, limit: }
  end

  def execute
    record_admin_write(action: "scheduled_payouts.execute", target: @scheduled_payout) do
      unless @scheduled_payout.pending? || @scheduled_payout.flagged?
        next render json: {
          success: false,
          message: "Cannot execute a #{@scheduled_payout.status} scheduled payout."
        }, status: :unprocessable_entity
      end

      @scheduled_payout.update!(status: "pending") if @scheduled_payout.flagged?

      result = @scheduled_payout.execute!
      message = case result
                when :held then "Payout is now on hold for manual release."
                when :flagged then "Payout was flagged for review instead of executing."
      end

      render json: {
        success: true,
        result: result.to_s,
        message:,
        scheduled_payout: serialize_scheduled_payout(@scheduled_payout)
      }
    rescue => e
      render_scheduled_payout_error(e)
    end
  end

  def cancel
    record_admin_write(action: "scheduled_payouts.cancel", target: @scheduled_payout) do
      @scheduled_payout.cancel!
      render json: { success: true, scheduled_payout: serialize_scheduled_payout(@scheduled_payout) }
    rescue => e
      render_scheduled_payout_error(e)
    end
  end

  private
    def fetch_scheduled_payout
      @scheduled_payout = ScheduledPayout.includes(:user, :created_by).find_by_external_id(params[:id])
      render json: { success: false, message: "Scheduled payout not found" }, status: :not_found if @scheduled_payout.blank?
    end

    def serialize_scheduled_payout(scheduled_payout, enrichment: nil)
      enrichment ||= Admin::ScheduledPayoutEnrichmentService.new([scheduled_payout]).call[scheduled_payout.user_id] || {}
      Admin::ScheduledPayoutPresenter.new(scheduled_payout:, enrichment:).props
    end

    def render_scheduled_payout_error(error)
      render json: { success: false, message: error.message }, status: :unprocessable_entity
    end
end
