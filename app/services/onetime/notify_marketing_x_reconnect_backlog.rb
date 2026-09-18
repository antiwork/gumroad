# frozen_string_literal: true

# Mails the sellers who were already stuck in the X reconnect fallback before the notification
# existed. They produce no new failure until they try again, which is the thing they do not know
# to do, so nothing else reaches them.
#
#   Onetime::NotifyMarketingXReconnectBacklog.process(dry_run: true)
#   Onetime::NotifyMarketingXReconnectBacklog.process
class Onetime::NotifyMarketingXReconnectBacklog
  BATCH_SIZE = 100

  def self.process(batch_size: BATCH_SIZE, dry_run: false)
    new(batch_size:, dry_run:).process
  end

  def initialize(batch_size: BATCH_SIZE, dry_run: false)
    @batch_size = batch_size
    @dry_run = dry_run
  end

  def process
    scanned = 0
    enqueued = 0
    sellers = Set.new

    Marketing::Action.alive_for_reconnect_notice.find_in_batches(batch_size: @batch_size) do |actions|
      ReplicaLagWatcher.watch unless @dry_run

      actions.each do |action|
        scanned += 1
        next unless sellers.add?(action.user_id)

        enqueued += 1
        next if @dry_run

        SendMarketingXReconnectEmailJob.perform_async(action.user_id)
      end
    end

    Rails.logger.info("NotifyMarketingXReconnectBacklog: #{enqueued} sellers from #{scanned} actions#{' (dry run)' if @dry_run}")
    { sellers: enqueued, actions_scanned: scanned }
  end
end
