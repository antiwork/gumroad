# frozen_string_literal: true

class AudienceController < Sellers::BaseController
  before_action :set_time_range, only: :index

  after_action :set_dashboard_preference_to_audience, only: :index
  before_action :check_payment_details, only: :index

  layout "inertia", only: :index

  def index
    authorize :audience

    total_follower_count = current_seller.audience_members.where(follower: true).count

    render inertia: "Analytics/Audience/Index", props: {
      total_follower_count:,
      audience_data: InertiaRails.defer do
        if total_follower_count.zero?
          nil
        else
          CreatorAnalytics::Following.new(current_seller).by_date(
            start_date: @start_date.to_date,
            end_date: @end_date.to_date
          )
        end
      end
    }
  end

  def export
    authorize :audience

    options = params.required(:options)
                 .permit(:followers, :customers, :affiliates)
                 .to_hash

    Exports::AudienceExportWorker.perform_async(current_seller.id, (impersonating_user || current_seller).id, options)

    head :ok
  end

  protected
    def set_time_range
      begin
        end_time = DateTime.parse(params[:to])
        start_date = DateTime.parse(params[:from])
      rescue StandardError
        end_time = DateTime.current
        start_date = end_time.ago(29.days)
      end
      @start_date = start_date
      @end_date = end_time
    end

    def set_title
      @title = "Analytics"
    end
end
