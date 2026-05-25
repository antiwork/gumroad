# frozen_string_literal: true

class Api::Internal::Admin::PayoutsController < Api::Internal::Admin::BaseController
  include Api::Internal::Admin::CursorPaginated

  before_action :fetch_user_for_read, only: [:index]
  before_action :fetch_user_for_write, only: [:pause, :resume, :issue]

  def index
    records, pagination = paginate_with_cursor(@user.payments.includes(:bank_account), order: [[:created_at, :desc], [:id, :desc]])
    payout_note = @user.comments.with_type_payout_note.alive.where(author_id: GUMROAD_ADMIN_ID).last&.content

    render json: {
      success: true,
      user_id: @user.external_id,
      recent_payouts: records.map { serialize_payout(_1) },
      pagination:,
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
          user_id: @user.external_id,
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
        user_id: @user.external_id,
        message: "Payouts paused for #{@user.external_id}",
        payouts_paused: true
      }
    end
  end

  def resume
    record_admin_write(action: "payouts.resume", target: @user) do
      unless @user.payouts_paused_internally?
        return render json: {
          success: true,
          user_id: @user.external_id,
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
        user_id: @user.external_id,
        message: "Payouts resumed for #{@user.external_id}",
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
        render json: { success: true, user_id: @user.external_id, payout: serialize_payout(payment) }
      end
    end
  end

  private
    def fetch_user_for_read
      @user = find_internal_admin_user_for_read_or_render
    end

    def fetch_user_for_write
      @user = find_internal_admin_user_for_write_or_render
    end
end
