# frozen_string_literal: true

# One immutable upload of a browser game for a product. The zip is copied into
# games/<product_id>/<number>/ on deploy, so later changes to the seller's source
# upload cannot alter it. Only `promote!` makes a build the one buyers get.
class GameBuild < ApplicationRecord
  include ExternalId

  STATUSES = %w[uploaded live superseded].freeze
  MAX_BUILDS_PER_PRODUCT = 50
  MAX_BYTE_SIZE = 2.gigabytes
  STORAGE_PREFIX = "games"

  belongs_to :link
  belongs_to :product_file, optional: true

  validates :number, :source_url, :storage_key, presence: true
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTE_SIZE }
  validates :status, inclusion: { in: STATUSES }

  scope :live, -> { where(status: "live") }

  def self.storage_key_for(link_id, number)
    "#{STORAGE_PREFIX}/#{link_id}/#{number}/build.zip"
  end

  def live? = status == "live"

  # Makes this build the one buyers download, superseding the current one. Serialised on the
  # product row so two concurrent promotes cannot leave two live builds.
  def promote!
    link.with_lock do
      reload
      next self if live?

      previous = link.game_builds.live.first
      if previous
        previous.product_file&.mark_deleted!
        previous.update!(status: "superseded")
      end

      file = link.product_files.create!(
        url: "#{S3_BASE_URL}#{storage_key}",
        display_name: "#{link.name.to_s.truncate(200)} build #{number}.zip",
      )
      update!(status: "live", promoted_at: Time.current, product_file: file)
      link.generate_product_files_archives!
      self
    end
  end
end
