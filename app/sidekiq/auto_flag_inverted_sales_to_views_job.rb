# frozen_string_literal: true

# Hourly sweep for products whose free sales have inverted against both their page views and
# the number of distinct browsers buying them — the signature of scripted checkouts being used
# to mail a scraped address list. See AutoFlagInvertedSalesToViews for the full rationale.
#
# On the default queue rather than low: the whole point is stopping an in-flight blast, and
# sitting behind a low-priority backlog for hours defeats that.
class AutoFlagInvertedSalesToViewsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  def perform
    product_ids = AutoFlagInvertedSalesToViews.new.process
    return if product_ids.empty?

    # Logged so a run that took products down is distinguishable from a quiet one without
    # having to go read the risk inbox.
    Rails.logger.info("AutoFlagInvertedSalesToViewsJob unpublished and flagged product ids: #{product_ids.join(", ")}")
  end
end
