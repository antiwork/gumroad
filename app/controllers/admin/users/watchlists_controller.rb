# frozen_string_literal: true

class Admin::Users::WatchlistsController < Admin::Users::BaseController
  before_action :fetch_user

  def create
    threshold = parse_revenue_threshold_cents
    return render json: { success: false, message: "Revenue threshold must be greater than zero." }, status: :unprocessable_content if threshold.nil?

    watched_user = @user.watched_users.create!(
      revenue_threshold_cents: threshold,
      notes: params.dig(:watched_user, :notes).presence,
      created_by: current_user
    )
    watched_user.sync!
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, message: e.record.errors.full_messages.first }, status: :unprocessable_content
  end

  def update
    watched_user = @user.active_watched_user
    return render json: { success: false, message: "User is not currently being watched." }, status: :unprocessable_content if watched_user.nil?

    threshold = parse_revenue_threshold_cents
    return render json: { success: false, message: "Revenue threshold must be greater than zero." }, status: :unprocessable_content if threshold.nil?

    watched_user.update!(
      revenue_threshold_cents: threshold,
      notes: params.dig(:watched_user, :notes).presence
    )
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { success: false, message: e.record.errors.full_messages.first }, status: :unprocessable_content
  end

  def destroy
    watched_user = @user.active_watched_user
    return render json: { success: false, message: "User is not currently being watched." }, status: :unprocessable_content if watched_user.nil?

    watched_user.mark_deleted!
    render json: { success: true }
  end

  private
    def parse_revenue_threshold_cents
      raw = params.dig(:watched_user, :revenue_threshold)
      return nil if raw.blank?

      cents = (BigDecimal(raw.to_s) * 100).round
      cents.positive? ? cents : nil
    rescue ArgumentError
      nil
    end
end
