# frozen_string_literal: true

class Onetime::BackfillRadarValueLists
  BATCH_SIZE = 500

  def self.process(batch_size: BATCH_SIZE)
    new(batch_size:).process
  end

  def initialize(batch_size: BATCH_SIZE)
    @batch_size = batch_size
    @service = Radar::ValueListSyncService.new
  end

  def process
    backfill_emails
    backfill_cards
  end

  private
    attr_reader :batch_size, :service

    def backfill_emails
      list = service.find_or_create_list(
        list_alias: Radar::ValueListSyncService::BLOCKED_EMAILS_LIST,
        name: "Gumroad Blocked Emails",
        item_type: "email"
      )

      total = 0
      PlatformBlock.email.active.in_batches(of: batch_size) do |batch|
        batch.each { |obj| service.add_item_to_list(list.id, obj.object_value) }
        total += batch.size
        puts "Radar email backfill: #{total} pushed"
      end
    end

    def backfill_cards
      list = service.find_or_create_list(
        list_alias: Radar::ValueListSyncService::BLOCKED_CARDS_LIST,
        name: "Gumroad Blocked Cards",
        item_type: "card_fingerprint"
      )

      total = 0
      PlatformBlock.charge_processor_fingerprint.active
        .where("object_value REGEXP ?", Radar::ValueListSyncService::STRIPE_FINGERPRINT_PATTERN.source)
        .in_batches(of: batch_size) do |batch|
        batch.each { |obj| service.add_item_to_list(list.id, obj.object_value) }
        total += batch.size
        puts "Radar card backfill: #{total} pushed"
      end
    end
end
