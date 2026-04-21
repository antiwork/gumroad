# frozen_string_literal: true

class Admin::ScheduledPayoutsController < Admin::BaseController
  include Pagy::Backend

  RECORDS_PER_PAGE = 20
  private_constant :RECORDS_PER_PAGE

  def index
    set_meta_tag(title: "Scheduled Payouts")

    scope = ScheduledPayout.includes(:user, :created_by).order(id: :desc)
    scope = scope.where(status: params[:status]) if params[:status].present? && ScheduledPayout::STATUSES.include?(params[:status])

    pagination, scheduled_payouts = pagy(scope, limit: RECORDS_PER_PAGE, page: params[:page])

    render inertia: "Admin/ScheduledPayouts/Index",
           props: {
             scheduled_payouts: scheduled_payouts.map { Admin::ScheduledPayoutPresenter.new(scheduled_payout: _1).props },
             pagination: PagyPresenter.new(pagination).props,
             current_status_filter: params[:status]
           }
  end

  def execute
    scheduled_payout = ScheduledPayout.find_by_external_id!(params[:external_id])

    if scheduled_payout.pending? || scheduled_payout.flagged?
      if scheduled_payout.flagged?
        scheduled_payout.update!(status: "pending")
      end
      result = scheduled_payout.execute!
      case result
      when :executed
        render json: { success: true }
      when :held
        render json: { success: true, message: "Payout is now on hold for manual release." }
      when :flagged
        render json: { success: true, message: "Payout was flagged for review instead of executing." }
      end
    else
      render json: { success: false, message: "Cannot execute a #{scheduled_payout.status} scheduled payout." }
    end
  rescue => e
    render json: { success: false, message: e.message }
  end

  def cancel
    scheduled_payout = ScheduledPayout.find_by_external_id!(params[:external_id])
    scheduled_payout.cancel!
    render json: { success: true }
  rescue => e
    render json: { success: false, message: e.message }
  end
end
