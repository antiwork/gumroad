# frozen_string_literal: true

class Products::PublishSchedulesController < Sellers::BaseController
  before_action :fetch_product

  def create
    schedule = ProductPublishSchedule.schedule!(product: @product, scheduled_by: logged_in_user, local_time: params[:local_time])
    render json: { success: true, publish_schedule: PublishSchedulePresenter.new(schedule).props }
  rescue ProductPublishSchedule::Invalid => e
    render json: { success: false, error_message: e.message }, status: :unprocessable_entity
  end

  def destroy
    cancelled = ProductPublishSchedule.cancel_pending!(@product.id, reason: "seller_cancelled")
    return render json: { success: false, error_message: "There is no pending schedule to cancel." }, status: :unprocessable_entity if cancelled.zero?

    render json: { success: true }
  end

  def dismiss_failure
    ProductPublishSchedule.where(product_id: @product.id, status: "failed", failure_dismissed_at: nil).update_all(failure_dismissed_at: Time.current)
    render json: { success: true }
  end

  private
    def fetch_product
      @product = Link.visible.find_by(unique_permalink: params[:link_id])
      return e404_json if @product.nil? || @product.user != current_seller

      authorize @product, :publish?
    end
end
