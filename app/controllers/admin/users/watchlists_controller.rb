# frozen_string_literal: true

class Admin::Users::WatchlistsController < Admin::Users::BaseController
  before_action :fetch_user
  before_action :validate_threshold, only: [:create, :update]
  before_action :fetch_active_watched_user, only: [:update, :destroy]

  rescue_from ActiveRecord::RecordInvalid do |e|
    render_error(e.record.errors.full_messages.first)
  end

  def create
    @user.watched_users.create!(
      revenue_threshold_cents: @threshold_cents,
      notes: notes_param,
      created_by: current_user
    ).sync!
    render json: { success: true }
  end

  def update
    @watched_user.update!(revenue_threshold_cents: @threshold_cents, notes: notes_param)
    render json: { success: true }
  end

  def destroy
    @watched_user.mark_deleted!
    render json: { success: true }
  end

  private
    def fetch_active_watched_user
      @watched_user = @user.active_watched_user
      render_error("User is not currently being watched.") if @watched_user.nil?
    end

    def validate_threshold
      @threshold_cents = parsed_threshold_cents
      render_error("Revenue threshold must be greater than zero.") if @threshold_cents.nil?
    end

    def parsed_threshold_cents
      raw = params.dig(:watched_user, :revenue_threshold)
      return nil if raw.blank?

      cents = (BigDecimal(raw.to_s) * 100).round
      cents.positive? ? cents : nil
    rescue ArgumentError
      nil
    end

    def notes_param
      params.dig(:watched_user, :notes).presence
    end

    def render_error(message)
      render json: { success: false, message: }, status: :unprocessable_content
    end
end
