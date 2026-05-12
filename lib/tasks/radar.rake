# frozen_string_literal: true

namespace :radar do
  desc "Backfill all active blocked emails and card fingerprints to Stripe Radar value lists"
  task backfill_value_lists: :environment do
    service = Radar::ValueListSyncService.new
    service.backfill_all
    puts "Backfill complete."
  end
end
