# frozen_string_literal: true

class SocialProofMetricsTrackerService
  attr_reader :widget

  def initialize(widget:)
    @widget = widget
  end

  # Track impression event - increments aggregate count
  def track_impression
    SocialProofWidgetMetric.increment_impressions(widget)
  end

  # Track click event - increments aggregate count
  def track_click
    SocialProofWidgetMetric.increment_clicks(widget)
  end

  # Track close event - increments aggregate count
  def track_close
    SocialProofWidgetMetric.increment_closes(widget)
  end

  # Track conversion event - creates a widget-purchase association
  def track_conversion(purchase)
    SocialProofWidgetConversion.track_conversion(widget, purchase)
  end
end
