# frozen_string_literal: true

# One immutable upload of a browser game for a product. The zip is copied into
# games/<product_id>/<number>/ on deploy, so later changes to the seller's source
# upload cannot alter it. Only `promote!` makes a build the one buyers get.
class GameBuild < ApplicationRecord
  STATUSES = %w[uploaded live superseded].freeze
  MAX_BUILDS_PER_PRODUCT = 50
  MAX_BYTE_SIZE = 2.gigabytes
  STORAGE_PREFIX = "games"
  PUBLIC_ID_ALPHABET = [*"0".."9", *"A".."Z", *"a".."z", "_", "-"].freeze

  belongs_to :product, class_name: "Link"
  belongs_to :product_file, optional: true

  before_validation :set_public_id, on: :create

  validates :number, :source_url, :storage_key, presence: true
  validates :byte_size, numericality: { greater_than: 0, less_than_or_equal_to: MAX_BYTE_SIZE }
  validates :status, inclusion: { in: STATUSES }

  scope :live, -> { where(status: "live") }

  def self.storage_key_for(product_id, number)
    "#{STORAGE_PREFIX}/#{product_id}/#{number}/build.zip"
  end

  def live? = status == "live"

  # Makes this build the one buyers get, superseding the current one. Serialised on the
  # product row so two concurrent promotes cannot leave two live builds.
  def promote!
    product.with_lock do
      reload
      next self if live?

      previous = product.game_builds.live.first
      if previous
        previous.product_file&.mark_deleted!
        previous.update!(status: "superseded")
      end

      file = product.product_files.create!(
        url: "#{S3_BASE_URL}#{storage_key}",
        display_name: "#{product.name.to_s.truncate(200)} build #{number}.zip",
      )
      update!(status: "live", promoted_at: Time.current, product_file: file)
      swap_file_embed(previous&.product_file, file)
      product.generate_product_files_archives!
      self
    end
  end

  private
    def set_public_id
      self.public_id ||= Array.new(21) { PUBLIC_ID_ALPHABET[SecureRandom.random_number(PUBLIC_ID_ALPHABET.size)] }.join
    end

    # Buyers of a product with content pages only see files embedded in them, so the live
    # build's zip is embedded on the first page and the superseded one is removed.
    def swap_file_embed(old_file, new_file)
      contents = product.has_product_level_rich_content? ? product.alive_rich_contents : product.alive_variants.flat_map(&:alive_rich_contents)
      contents.each do |content|
        nodes = old_file ? RichContent.reject_file_embeds(content.description, [old_file.id]) : content.description.to_a
        if content == contents.first
          nodes += [{ "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => new_file.external_id, "uid" => SecureRandom.uuid } }]
        end
        content.update!(description: nodes)
      end
    end
end
