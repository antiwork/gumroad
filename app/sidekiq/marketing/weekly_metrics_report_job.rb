# frozen_string_literal: true

class Marketing::WeeklyMetricsReportJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(window_end = nil)
    window_end = window_end ? Time.iso8601(window_end).utc : Time.current.utc.beginning_of_week
    window_start = window_end - 90.days
    Marketing::MetricsReport::COHORTS.each_key do |cohort|
      metrics = Marketing::MetricsReport.new(window_start:, window_end:, cohort:).call
      snapshot = Marketing::MetricsSnapshot.find_or_initialize_by(window_start:, window_end:, cohort:)
      snapshot.update!(metrics: metrics.merge(report_text: Marketing::MetricsReport.render(metrics)))
    end
  end
end
