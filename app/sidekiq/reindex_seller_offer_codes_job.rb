# frozen_string_literal: true

class ReindexSellerOfferCodesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 10, lock: :until_executing

  BATCH_SIZE = 25
  INTERVAL = 5.seconds
  LOCK_TTL = 10.minutes
  LockLost = Class.new(StandardError)

  sidekiq_retries_exhausted do |message, _error|
    ReindexSellerOfferCodesRecoveryJob.perform_in(1.hour, message.fetch("args").first)
  end

  def self.enqueue(seller_id)
    $redis.incr("offer_code_index:#{seller_id}:version")
    perform_async(seller_id)
  end

  def self.enqueue_products(seller_id, product_ids)
    return if product_ids.empty?

    $redis.eval(<<~LUA, keys: ["offer_code_index:#{seller_id}:products", "offer_code_index:#{seller_id}:sequence", "offer_code_index:#{seller_id}:product_versions"], argv: product_ids)
      local version = redis.call('INCR', KEYS[2])
      for _, id in ipairs(ARGV) do
        redis.call('ZADD', KEYS[1], 'NX', version, id)
        redis.call('HSET', KEYS[3], id, version)
      end
    LUA
    perform_async(seller_id)
  end

  def perform(seller_id)
    key = "offer_code_index:#{seller_id}"
    token = SecureRandom.hex(16)
    unless $redis.set("#{key}:lock", token, nx: true, ex: LOCK_TTL.to_i)
      self.class.perform_in(INTERVAL, seller_id)
      return
    end
    renew_lock = lambda do
      renewed = $redis.eval("if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], ARGV[2]) end", keys: ["#{key}:lock"], argv: [token, LOCK_TTL.to_i])
      raise LockLost unless renewed == 1
    end
    begin
      if $redis.get("#{key}:cooldown").to_f > Time.current.to_f
        self.class.perform_in(INTERVAL, seller_id)
        return
      end

      pending_ids = $redis.zrange("#{key}:products", 0, BATCH_SIZE - 1)
      pending = pending_ids.zip(pending_ids.any? ? $redis.hmget("#{key}:product_versions", *pending_ids) : [])
      catalogue_pending = $redis.exists?("#{key}:version")
      if pending_ids.any? && (!catalogue_pending || $redis.get("#{key}:last_batch") != "targeted")
        $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
        attempted = true
        $redis.set("#{key}:last_batch", "targeted")
        # The enqueue follows the offer-code or product write that just committed, so the product
        # load and the service's own OfferCode queries both have to see it.
        ApplicationRecord.connected_to(role: :writing) do
          ProductOfferCodeIndexingService.new(Link.where(id: pending_ids).to_a).perform(&renew_lock)
        end
        renew_lock.call
        self.class.perform_in(INTERVAL, seller_id)
        pending.each do |product_id, version|
          $redis.eval(<<~LUA, keys: ["#{key}:products", "#{key}:sequence", "#{key}:product_versions"], argv: [product_id, version])
            if redis.call('HGET', KEYS[3], ARGV[1]) == ARGV[2] then
              redis.call('ZREM', KEYS[1], ARGV[1])
              redis.call('HDEL', KEYS[3], ARGV[1])
            else
              redis.call('ZADD', KEYS[1], redis.call('INCR', KEYS[2]), ARGV[1])
            end
          LUA
        end
        $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
        return
      end

      version = $redis.get("#{key}:version")
      return unless version

      $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
      cursor, scan_version = $redis.mget("#{key}:cursor", "#{key}:scan_version")
      scan_version ||= version
      # Include unpublished/banned rows: offer_codes can go stale while a product is
      # inactive, and republication does not otherwise refresh them.
      products = ApplicationRecord.connected_to(role: :writing) do
        Link.visible.where(user_id: seller_id).where("id > ?", cursor.to_i).order(:id).limit(BATCH_SIZE).to_a
      end
      attempted = true
      $redis.set("#{key}:last_batch", "catalogue")
      # Same reason as the targeted branch: the scan above and the service's OfferCode queries
      # must see the write that enqueued this run.
      ApplicationRecord.connected_to(role: :writing) { ProductOfferCodeIndexingService.new(products).perform(&renew_lock) }
      renew_lock.call

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
    ensure
      begin
        $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i) if attempted
      ensure
        $redis.eval("if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end", keys: ["#{key}:lock"], argv: [token])
      end
    end
  end
end
