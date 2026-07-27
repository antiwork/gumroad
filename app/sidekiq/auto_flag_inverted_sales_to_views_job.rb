# frozen_string_literal: true

# Hourly sweep for products whose sales have inverted against their page views — the
# signature of scripted free checkouts being used to mail a scraped address list. See
# AutoFlagInvertedSalesToViews for what it looks for and what it does about it.
class AutoFlagInvertedSalesToViewsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform
    AutoFlagInvertedSalesToViews.new.process
  end
end
