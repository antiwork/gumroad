# frozen_string_literal: true

class Radar::SyncValueListsJob
  include Sidekiq::Job

  sidekiq_options queue: "low", retry: 3

  def perform
    service = Radar::ValueListSyncService.new
    service.sync_blocked_emails
    service.sync_blocked_cards
  end
end
