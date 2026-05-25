# frozen_string_literal: true

class Api::Internal::Admin::ScheduledPayoutsController < Api::Internal::Admin::BaseController
  DEFAULT_LIMIT = 20
  MAX_LIMIT = 50
  DEFAULT_PAYOUT_DELAY_DAYS = 21
  private_constant :DEFAULT_LIMIT, :MAX_LIMIT, :DEFAULT_PAYOUT_DELAY_DAYS

  before_action :fetch_scheduled_payout, only: [:execute, :cancel]

  def create
    processor = normalized_payout_processor
    return render json: { success: false, message: "processor is required" }, status: :bad_request if params[:processor].blank?
    return render json: { success: false, message: "processor must be stripe or paypal" }, status: :bad_request if processor.blank?

    today = current_utc_date
    payout_date = parse_payout_date_or_render(today)
    return unless payout_date

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "scheduled_payouts.create", target: user) do
      delay_days = (payout_date - today).to_i

      scheduled_payout = nil
      failure_message = nil

      User.transaction do
        user.lock!

        if !user.suspended?
          failure_message = "User is not suspended."
        elsif user.scheduled_payouts.in_progress.exists?
          failure_message = "User already has a scheduled payout in progress"
        elsif user.unpaid_balance_cents.to_i <= 0
          failure_message = "User has no unpaid balance."
        else
          payout_note = build_scheduled_payout_note(user:, payout_date:, delay_days:, processor:, note: params[:note])
          failure_message = payout_note.errors.full_messages.to_sentence if payout_note.invalid?

          if failure_message.blank?
            scheduled_payout = user.scheduled_payouts.create!(
              action: "payout",
              delay_days:,
              scheduled_at: payout_date.in_time_zone("UTC"),
              processor:,
              payout_amount_cents: user.unpaid_balance_cents,
              created_by: Current.admin_actor
            )
            payout_note.save!
          end
        end

        raise ActiveRecord::Rollback if failure_message.present?
      end

      return render json: { success: false, message: failure_message }, status: :unprocessable_entity if failure_message.present?

      render json: {
        success: true,
        user_id: user.external_id,
        message: "Scheduled payout created",
        scheduled_payout: serialize_scheduled_payout(scheduled_payout)
      }
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, message: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

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

    def normalized_payout_processor
      processor = params[:processor].to_s.upcase
      processor if PayoutProcessorType.all.include?(processor)
    end

    def parse_payout_date_or_render(today)
      payout_date = if params[:payout_date].present?
        Date.iso8601(params[:payout_date].to_s)
      else
        today + DEFAULT_PAYOUT_DELAY_DAYS
      end

      if payout_date < today
        render json: { success: false, message: "payout_date cannot be in the past" }, status: :bad_request
        return
      end

      payout_date
    rescue ArgumentError
      render json: { success: false, message: "payout_date is invalid" }, status: :bad_request
      nil
    end

    def current_utc_date
      Time.current.utc.to_date
    end

    def build_scheduled_payout_note(user:, payout_date:, delay_days:, processor:, note:)
      content = "Scheduled payout via #{processor.downcase} for #{payout_date.in_time_zone("UTC").to_fs(:formatted_date_full_month)} (#{delay_days} day delay)"
      content += "\nNote: #{note}" if note.present?

      user.comments.new(
        author_id: current_admin_actor_id,
        author_name: Current.admin_actor.name,
        comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
        content:
      )
    end

    def render_scheduled_payout_error(error)
      render json: { success: false, message: error.message }, status: :unprocessable_entity
    end
end
