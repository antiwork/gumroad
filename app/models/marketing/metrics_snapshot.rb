# frozen_string_literal: true

class Marketing::MetricsSnapshot < ApplicationRecord
  validates :window_start, :window_end, :metrics, presence: true
  validates :cohort, inclusion: { in: Marketing::MetricsReport::COHORTS.keys }
  validates :cohort, uniqueness: { scope: [:window_start, :window_end] }

  def report_text
    Marketing::MetricsReport.render(metrics.deep_symbolize_keys)
  end
end
