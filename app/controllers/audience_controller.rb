# frozen_string_literal: true

class AudienceController < Sellers::BaseController
  before_action :set_body_id_as_app
  before_action :set_time_range, only: %i[data_by_date]

  after_action :set_dashboard_preference_to_audience, only: :index
  before_action :check_payment_details, only: :index

  def index
    authorize :audience

    @total_follower_count = current_seller.audience_members.where(follower: true).count
  end

  def export
    authorize :audience

    options = params.required(:options)
                 .permit(:followers, :customers, :affiliates)
                 .to_hash

    seller = seller_for_export
    recipient = impersonating_user || seller

    Exports::AudienceExportWorker.perform_async(seller.id, recipient.id, options)

    head :ok
  end

  def data_by_date
    authorize :audience, :index?

    data = CreatorAnalytics::Following.new(current_seller).by_date(start_date: @start_date.to_date, end_date: @end_date.to_date)

    render json: data
  end

  private
    # When impersonating, we must use logged_in_user (the impersonated user), not current_seller.
    # See PurchasesController#seller_for_export for detailed explanation.
    def seller_for_export
      return current_seller unless impersonating?

      if current_seller != logged_in_user
        Rails.logger.warn(
          "[Impersonation] Seller mismatch during audience export: " \
          "current_seller=#{current_seller.id}, logged_in_user=#{logged_in_user.id}"
        )
      end

      logged_in_user
    end

  protected
    def set_time_range
      begin
        end_time = DateTime.parse(params[:end_time])
        start_date = DateTime.parse(params[:start_time])
      rescue StandardError
        end_time = DateTime.current
        start_date = end_time.ago(29.days)
      end
      @start_date = start_date
      @end_date = end_time
      @timezone_offset = end_time.zone
    end

    def set_title
      @title = "Analytics"
    end
end
