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

    audience_csv = Exports::AudienceExportService.new(current_seller).perform
    send_data audience_csv, type: "text/csv"
  end

  def data_by_date
    authorize :audience, :index?

    data = CreatorAnalytics::Following.new(current_seller).by_date(start_date: @start_date.to_date, end_date: @end_date.to_date)

    render json: data
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
