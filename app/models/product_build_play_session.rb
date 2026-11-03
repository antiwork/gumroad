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

  # Extends an open session. A beat that arrives after the expiry is dropped: the session is over, and
  # the buyer is on a page load that started a new one.
  def heartbeat!(at = Time.current)
    return false unless open?(at)

    update!(last_heartbeat_at: at)
    true
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
end
