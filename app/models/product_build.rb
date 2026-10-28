# frozen_string_literal: true

# One immutable upload of a web build (a game, an interactive course) for a product.
# The zip is copied into builds/<product_id>/<number>/ on deploy, so later changes to
# the seller's source upload cannot alter it. Only `promote!` makes a build the one buyers get.
class ProductBuild < ApplicationRecord
  STATUSES = %w[uploaded live superseded].freeze
  MAX_BUILDS_PER_PRODUCT = 50
  MAX_BYTE_SIZE = 2.gigabytes
  # Limits on what a zip may unpack to. The zip itself is capped at MAX_BYTE_SIZE, but a small
  # archive can still expand into far more, so the unpack stops at these.
  SITE_DIRECTORY = "site"
  MAX_SITE_FILES = 5_000
  MAX_SITE_BYTE_SIZE = 4.gigabytes
  PUBLIC_ID_LENGTH = 21
  DISPLAY_NAME_MAX_LENGTH = 200
  STORAGE_PREFIX = "builds"
  PUBLIC_ID_ALPHABET = [*"0".."9", *"A".."Z", *"a".."z", "_", "-"].freeze
  PLAYER_GRANT_PURPOSE = "product_build_player"
  # Long enough for one play session. A refund or revoked access stops new sessions at once, and
  # running ones when the grant expires.
  PLAYER_GRANT_VALID_FOR = 12.hours

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

  # Where the player serves this build's files from. The zip stays next to it as build.zip.
  def site_prefix
    "#{STORAGE_PREFIX}/#{product_id}/#{number}/#{SITE_DIRECTORY}"
  end

  # True once the zip has been unpacked into site_prefix. A build whose zip was rejected is not
  # ready: the seller has to upload a fixed zip as a new build.
  def site_ready? = site_unpacked_at.present?

  def live? = status == "live"

  # An encrypted path segment that lets the player's frame load this build's files for one purchase.
  # The frame is an opaque origin, so its file requests carry no session cookies: the access check
  # runs once, on the content-page token, and the grant carries the result until it expires.
  def player_grant(url_redirect_token:, purchase_id:)
    self.class.player_grant_encryptor.encrypt_and_sign(
      { "token" => url_redirect_token, "purchase_id" => purchase_id, "seller_id" => product.user_id, "site_prefix" => site_prefix },
      purpose: PLAYER_GRANT_PURPOSE,
      expires_in: PLAYER_GRANT_VALID_FOR,
    )
  end

  # The grant's payload when it is valid and was issued for this content-page token, or nil.
  def self.verified_player_grant(grant, url_redirect_token:)
    payload = player_grant_encryptor.decrypt_and_verify(grant.to_s, purpose: PLAYER_GRANT_PURPOSE)
    payload if payload.is_a?(Hash) && payload["token"] == url_redirect_token
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  # Encrypted, not only signed: the grant is in the frame's URL, and it holds internal ids.
  # url_safe because it is a path segment.
  def self.player_grant_encryptor
    @player_grant_encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("product_build_player_grant", ActiveSupport::MessageEncryptor.key_len),
      url_safe: true, serializer: JSON,
    )
  end

  # Makes this build the one buyers get, superseding the current one. Promoting the live build again
  # restores its download if the seller deleted it and delivers it to versions added since.
  # Serialised on the product row so two concurrent promotes cannot leave two live builds.
  def promote!
    product.with_lock do
      reload
      if live? && product_file&.alive?
        swap_file_embed(nil, product_file)
        product.generate_product_files_archives!
        next self
      end

      previous = product.product_builds.live.where.not(id:).first
      if previous
        previous.product_file&.mark_deleted!
        previous.update!(status: "superseded")
      end
      replaced_file = live? ? product_file : previous&.product_file

      file = product.product_files.create!(
        url: "#{S3_BASE_URL}#{storage_key}",
        display_name: "#{product.name.to_s.truncate(DISPLAY_NAME_MAX_LENGTH)} build #{number}.zip",
      )
      update!(status: "live", promoted_at: Time.current, product_file: file)
      swap_file_embed(replaced_file, file)
      product.generate_product_files_archives!
      self
    end

    # The player serves the unpacked site/, so the zip is unpacked as soon as the build is the one
    # buyers get. Queued outside the lock: the job reads this row and must not run before it commits.
    ProductBuildUnpackJob.perform_async(id)
    self
  end

  private
    def set_public_id
      self.public_id ||= Array.new(PUBLIC_ID_LENGTH) { PUBLIC_ID_ALPHABET[SecureRandom.random_number(PUBLIC_ID_ALPHABET.size)] }.join
    end

    # Buyers only see files embedded in content pages, so the live zip goes on the first page of
    # the product (or of each variant) and the superseded one is removed everywhere.
    def swap_file_embed(old_file, new_file)
      per_variant = !product.has_product_level_rich_content?
      contents = per_variant ? product.alive_variants.flat_map { _1.alive_rich_contents.to_a } : []
      # Buyers without a version still read the product's own pages while any has content (UrlRedirect).
      contents += product.alive_rich_contents.to_a if !per_variant || product.alive_rich_contents.any?(&:has_editor_content?)
      contents.group_by { [_1.entity_type, _1.entity_id] }.each_value do |pages|
        embedded = pages.any? { _1.embedded_product_file_ids_in_order.include?(new_file.id) }
        first_page = pages.min_by(&:position)
        pages.each do |content|
          nodes = old_file ? RichContent.reject_file_embeds(content.description, [old_file.id]) : content.description.to_a
          nodes += [file_embed_node(new_file)] if content == first_page && !embedded
          content.update!(description: nodes) unless nodes == content.description
        end
      end
      return unless per_variant

      # A variant's buyers get only its linked files, and every save relinks them from the variant's
      # page embeds, so a variant without pages gets one holding the zip.
      product.alive_variants.each do |variant|
        if variant.alive_rich_contents.none?
          existing = variant.product_files.alive.where.not(id: [old_file&.id, new_file.id].compact).in_order
          variant.alive_rich_contents.create!(description: (existing.to_a + [new_file]).map { file_embed_node(_1) })
        end
        variant.product_files.delete(old_file) if old_file
        variant.product_files << new_file unless variant.product_files.include?(new_file)
      end
    end

    def file_embed_node(file)
      { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
    end
end
