# frozen_string_literal: true

class ReindexSellerOfferCodesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 10, lock: :until_executing

  BATCH_SIZE = 25
  INTERVAL = 5.seconds

  def self.enqueue(seller_id)
    $redis.incr("offer_code_index:#{seller_id}:version")
    perform_async(seller_id)
  end

  def perform(seller_id)
    key = "offer_code_index:#{seller_id}"
    semaphore = Suo::Client::Redis.new("#{key}:lock", client: $redis)
    acquired = false
    semaphore.lock do
      acquired = true
      if $redis.get("#{key}:cooldown").to_f > Time.current.to_f
        self.class.perform_in(INTERVAL, seller_id)
        next
      end

      version = $redis.get("#{key}:version")
      next unless version

      $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
      ActiveRecord::Base.connection.stick_to_primary!
      cursor, scan_version = $redis.mget("#{key}:cursor", "#{key}:scan_version")
      scan_version ||= version
      products = Link.where(user_id: seller_id).where("id > ?", cursor.to_i).order(:id).limit(BATCH_SIZE).to_a
      ProductOfferCodeIndexingService.new(products).perform

      # Schedule before advancing: a failed push retries this batch, never skips it.
      self.class.perform_in(INTERVAL, seller_id)
      $redis.multi do |redis|
        redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
        if products.size == BATCH_SIZE
          redis.set("#{key}:cursor", products.last.id)
          redis.set("#{key}:scan_version", scan_version)
        else
          redis.del("#{key}:cursor", "#{key}:scan_version")
        end
      end
      if products.size < BATCH_SIZE
        # An edit during the scan needs another pass, including products behind the cursor.
        $redis.eval("if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end", keys: ["#{key}:version"], argv: [scan_version])
      end
    end
    self.class.perform_in(INTERVAL, seller_id) unless acquired
  end
end
