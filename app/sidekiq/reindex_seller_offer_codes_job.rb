# frozen_string_literal: true

class ReindexSellerOfferCodesJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 10, lock: :until_executing

  BATCH_SIZE = 25
  INTERVAL = 5.seconds

  sidekiq_retries_exhausted do |message, _error|
    perform_in(1.hour, message.fetch("args").first)
  end

  def self.enqueue(seller_id)
    $redis.incr("offer_code_index:#{seller_id}:version")
    perform_async(seller_id)
  end

  def self.enqueue_products(seller_id, product_ids)
    return if product_ids.empty?

    $redis.hset("offer_code_index:#{seller_id}:products", product_ids.index_with { SecureRandom.hex(16) })
    perform_async(seller_id)
  end

  def perform(seller_id)
    key = "offer_code_index:#{seller_id}"
    token = SecureRandom.hex(16)
    unless $redis.set("#{key}:lock", token, nx: true, ex: 1.hour.to_i)
      self.class.perform_in(INTERVAL, seller_id)
      return
    end
    begin
      if $redis.get("#{key}:cooldown").to_f > Time.current.to_f
        self.class.perform_in(INTERVAL, seller_id)
        return
      end

      pending_ids = $redis.hscan_each("#{key}:products", count: BATCH_SIZE).take(BATCH_SIZE).map(&:first)
      if pending_ids.any?
        versions = $redis.hmget("#{key}:products", *pending_ids)
        $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
        ActiveRecord::Base.connection.stick_to_primary!
        ProductOfferCodeIndexingService.new(Link.where(id: pending_ids).to_a).perform
        self.class.perform_in(INTERVAL, seller_id)
        pending_ids.zip(versions).each do |product_id, version|
          $redis.eval("if redis.call('HGET', KEYS[1], ARGV[1]) == ARGV[2] then return redis.call('HDEL', KEYS[1], ARGV[1]) end", keys: ["#{key}:products"], argv: [product_id, version])
        end
        $redis.set("#{key}:cooldown", (Time.current + INTERVAL).to_f, ex: INTERVAL.to_i)
        return
      end

      version = $redis.get("#{key}:version")
      return unless version

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
    ensure
      $redis.eval("if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end", keys: ["#{key}:lock"], argv: [token])
    end
  end
end
