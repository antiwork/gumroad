# frozen_string_literal: true

class SocialProofWidgetAnalyticsJob
  include Sidekiq::Worker

  sidekiq_options queue: 'low', retry: 3

  def perform(date_string = nil)
    date = date_string ? Date.parse(date_string) : Date.yesterday

    Rails.logger.info "Calculating social proof widget analytics for #{date}"

    SocialProofWidgetAnalytic.calculate_for_date(date)

    Rails.logger.info "Completed calculating social proof widget analytics for #{date}"
  end
end
