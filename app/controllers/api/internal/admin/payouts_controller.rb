# frozen_string_literal: true

class Api::Internal::Admin::PayoutsController < Api::Internal::Admin::BaseController
  SCHEDULED_PAYOUTS_DEFAULT_LIMIT = 20
  SCHEDULED_PAYOUTS_MAX_LIMIT = 50
  private_constant :SCHEDULED_PAYOUTS_DEFAULT_LIMIT, :SCHEDULED_PAYOUTS_MAX_LIMIT

  before_action :fetch_user, only: [:list, :pause, :resume, :issue]
  before_action :fetch_scheduled_payout, only: [:scheduled_execute, :scheduled_cancel]

  def list
    payouts = @user.payments.order(created_at: :desc).limit(5).map { serialize_payout(_1) }
    payout_note = @user.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last&.content

    render json: {
      success: true,
      last_payouts: payouts,
      next_payout_date: @user.next_payout_date,
      balance_for_next_payout: @user.formatted_balance_for_next_payout_date,
      payout_note:
    }
  end

  def pause
    record_admin_write(action: "payouts.pause", target: @user) do
      if @user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_ADMIN
        return render json: {
          success: true,
          status: "already_paused",
          message: "Payouts are already paused by admin",
          payouts_paused: true
        }
      end

      reason = params[:reason].to_s.strip.presence

      User.transaction do
        @user.update!(payouts_paused_internally: true, payouts_paused_by: current_admin_actor_id)
        if reason.present?
          @user.comments.create!(
            author_id: current_admin_actor_id,
            comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
            content: reason
          )
        end
      end

      render json: {
        success: true,
        message: "Payouts paused for #{@user.email}",
        payouts_paused: true
      }
    end
  end

  def resume
    record_admin_write(action: "payouts.resume", target: @user) do
      unless @user.payouts_paused_internally?
        return render json: {
          success: true,
          status: "not_paused",
          message: "Payouts are not paused by admin",
          payouts_paused: @user.payouts_paused?
        }
      end

      User.transaction do
        @user.update!(payouts_paused_internally: false, payouts_paused_by: nil)
        @user.comments.create!(
          author_id: current_admin_actor_id,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
          content: "Payouts resumed."
        )
      end

      render json: {
        success: true,
        message: "Payouts resumed for #{@user.email}",
        payouts_paused: @user.reload.payouts_paused?
      }
    end
  end

  def issue
    processor_param = params[:payout_processor].to_s.upcase
    unless PayoutProcessorType.all.include?(processor_param)
      return render json: { success: false, message: "payout_processor must be stripe or paypal" }, status: :bad_request
    end

    if params[:payout_period_end_date].blank?
      return render json: { success: false, message: "payout_period_end_date is required" }, status: :bad_request
    end

    begin
      date = Date.parse(params[:payout_period_end_date].to_s)
    rescue ArgumentError
      return render json: { success: false, message: "payout_period_end_date is invalid" }, status: :bad_request
    end

    if date >= Date.current
      return render json: { success: false, message: "payout_period_end_date must be in the past" }, status: :bad_request
    end

    record_admin_write(action: "payouts.issue", target: @user) do
      if processor_param == PayoutProcessorType::PAYPAL && ActiveModel::Type::Boolean.new.cast(params[:should_split_the_amount])
        @user.update!(should_paypal_payout_be_split: true)
      end

      payments = Payouts.create_payments_for_balances_up_to_date_for_users(date, processor_param, [@user], from_admin: true)
      payment = payments.first&.first

      if payment.blank? || payment.failed?
        render json: {
          success: false,
          message: payment&.errors&.full_messages&.first || "Payment was not sent."
        }, status: :unprocessable_entity
      else
        render json: { success: true, payout: serialize_payout(payment) }
      end
    end
  end

  def scheduled_list
    scope = ScheduledPayout.includes(:user, :created_by).order(id: :desc)
    if params[:status].present?
      unless ScheduledPayout::STATUSES.include?(params[:status])
        return render json: { success: false, message: "status is invalid" }, status: :bad_request
      end
      scope = scope.where(status: params[:status])
    end

    limit = params[:limit].to_i
    limit = SCHEDULED_PAYOUTS_DEFAULT_LIMIT if limit <= 0
    limit = [limit, SCHEDULED_PAYOUTS_MAX_LIMIT].min

    scheduled_payouts = scope.limit(limit).map { serialize_scheduled_payout(_1) }

    render json: { success: true, scheduled_payouts:, limit: }
  end

  def scheduled_execute
    record_admin_write(action: "payouts.scheduled_execute", target: @scheduled_payout) do
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

  def scheduled_cancel
    record_admin_write(action: "payouts.scheduled_cancel", target: @scheduled_payout) do
      @scheduled_payout.cancel!
      render json: { success: true, scheduled_payout: serialize_scheduled_payout(@scheduled_payout) }
    rescue => e
      render_scheduled_payout_error(e)
    end
  end

  private
    def fetch_user
      return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

      @user = User.alive.by_email(params[:email]).first
      render json: { success: false, message: "User not found" }, status: :not_found if @user.blank?
    end

    def fetch_scheduled_payout
      @scheduled_payout = ScheduledPayout.includes(:user, :created_by).find_by_external_id(params[:id])
      render json: { success: false, message: "Scheduled payout not found" }, status: :not_found if @scheduled_payout.blank?
    end

    def serialize_scheduled_payout(scheduled_payout)
      Admin::ScheduledPayoutPresenter.new(scheduled_payout:).props
    end

    def render_scheduled_payout_error(error)
      render json: { success: false, message: error.message }, status: :unprocessable_entity
    end
end
