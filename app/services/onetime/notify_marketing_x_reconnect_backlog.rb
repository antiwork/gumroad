# frozen_string_literal: true

# Mails the sellers who were already stuck in the X reconnect fallback before the notification
# existed.
#
# Until PR #7757 the X connect link sent `x_auth_access_type=read`, which caps the OAuth 1.0a
# grant, so every seller who connected got a token that cannot post. Those actions sit open with
# `error_code = "x_write_permission_missing"` and nothing tells the seller, because the only
# surface is the card on the product's Share tab. A new failure would now mail them, but these
# sellers will not produce one until they try again — which is the thing they do not know to do.
#
# Idempotent: the job claims `reconnect_notified_at` before delivering, so a second run skips
# everyone the first run reached.
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
        # One email per seller. find_in_batches walks by id, so a seller with several stuck
        # products is mailed about their earliest one.
        next unless sellers.add?(action.user_id)

        enqueued += 1
        SendMarketingXReconnectEmailJob.perform_async(action.id) unless @dry_run
      end
    end

    Rails.logger.info("NotifyMarketingXReconnectBacklog: #{enqueued} sellers from #{scanned} actions#{' (dry run)' if @dry_run}")
    { sellers: enqueued, actions_scanned: scanned }
  end
end
