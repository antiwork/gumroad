# frozen_string_literal: true

# One play of a web build: a row per player page load, kept open by the page's heartbeats. The seller
# sees the count and the average length next to the product's sales.
class ProductBuildPlaySession < ApplicationRecord
  # How often the player page beats, and how old its last beat may be before the session is over. A
  # background tab's timers are throttled to about once a minute, so the expiry has to clear two
  # missed beats: a session closes roughly two minutes after the last one.
  HEARTBEAT_INTERVAL = 30.seconds
  SESSION_EXPIRY = 2.minutes

  belongs_to :product, class_name: "Link"
  belongs_to :product_build
  belongs_to :purchase

  # A player page load starts a session. The product comes from the build, which never changes it, so
  # the seller's products page can group a page of products without joining through the builds.
  def self.start!(product_build:, purchase:, at: Time.current)
    create!(product_id: product_build.product_id, product_build:, purchase:, started_at: at, last_heartbeat_at: at)
  end

  # Extends an open session and returns it. A beat after the expiry means the page woke up from a
  # sleep or an outage: it moves to a new session started at that beat, so the gap is not counted.
  # The page keeps beating the old path until it reads the answer, so a replacement already made
  # for this one, recorded in replacement_id, is reused rather than started again.
  def heartbeat!(at = Time.current)
    return resume!(at) unless open?(at)

    extend_to!(at)
  end

  # A session is over once its last beat is older than the expiry, and its length is final.
  def open?(at = Time.current) = at - last_heartbeat_at <= SESSION_EXPIRY

  def duration_seconds = (last_heartbeat_at - started_at).round

  # { product_id => { count:, average_seconds: } } for the products listed on one page, so the whole
  # page costs two queries rather than one per product. A product with no sessions is absent.
  def self.stats_by_product(product_ids)
    where(product_id: product_ids)
      .group(:product_id)
      .pluck(Arel.sql("product_id, COUNT(*), AVG(TIMESTAMPDIFF(SECOND, started_at, last_heartbeat_at))"))
      .to_h { |product_id, count, average_seconds| [product_id, { count:, average_seconds: average_seconds.to_f.round }] }
  end

  private
    def resume!(at)
      with_lock do
        if replacement_id
          # A plain read here would use this transaction's snapshot, which can predate a replacement
          # another beat committed while this one waited for the lock.
          self.class.lock.find(replacement_id).heartbeat!(at)
        elsif open?(at)
          # Another beat extended this session after this one loaded it.
          extend_to!(at)
        else
          self.class.start!(product_build:, purchase:, at:).tap { |replacement| update!(replacement_id: replacement.id) }
        end
      end
    end

    # A beat's time is taken before it waits for any lock, and this copy of the row may predate a later
    # beat, so beats can land out of order. GREATEST keeps the stored last beat from moving back.
    def extend_to!(at)
      self.class.where(id:).update_all(["last_heartbeat_at = GREATEST(last_heartbeat_at, ?), updated_at = ?", at, Time.current])
      self.last_heartbeat_at = [last_heartbeat_at, at].max
      clear_attribute_changes([:last_heartbeat_at])
      self
    end
end
