# frozen_string_literal: true

class RebuildGmailAbuseFilterJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :low

  def perform
    GmailAbuseFilter.rebuild!
  end
end
