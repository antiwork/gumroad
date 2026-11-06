# frozen_string_literal: true

# One immutable upload of a web build (a game, an interactive course) for a product.
# The zip is copied into builds/<product_id>/<number>/ on deploy, so later changes to
# the seller's source upload cannot alter it. Only `promote!` makes a build the one buyers get.
class ProductBuild < ApplicationRecord
  include TimestampStateFields
  STATUSES = %w[uploaded live superseded].freeze
  MAX_BUILDS_PER_PRODUCT = 50
  # Per unproven seller (ContentModeration::GumroadImpersonation.unproven_seller?), across all their products.
  MAX_DAILY_BUILDS_FOR_UNPROVEN_SELLER = 10
  MAX_BYTE_SIZE = 2.gigabytes
  # Limits on what a zip may unpack to. The zip itself is capped at MAX_BYTE_SIZE, but a small
  # archive can still expand into far more, so the unpack stops at these.
  SITE_DIRECTORY = "site"
  MAX_SITE_FILES = 5_000
  MAX_SITE_BYTE_SIZE = 4.gigabytes
  # The player reads a page into memory to put the save shim in it, so pages have a limit of their
  # own. Every other file is streamed.
  PAGE_EXTENSIONS = %w[html htm].freeze
  MAX_PAGE_BYTE_SIZE = 10.megabytes
  # What the browser needs to run a build's files without sniffing them, by extension. The player
  # serves files with these, never with the type stored on the object.
  CONTENT_TYPES = {
    "html" => "text/html",
    "htm" => "text/html",
    "js" => "text/javascript",
    "mjs" => "text/javascript",
    "cjs" => "text/javascript",
    "css" => "text/css",
    "json" => "application/json",
    "wasm" => "application/wasm",
    "txt" => "text/plain",
    "xml" => "application/xml",
    "svg" => "image/svg+xml",
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "avif" => "image/avif",
    "ico" => "image/vnd.microsoft.icon",
    "mp3" => "audio/mpeg",
    "ogg" => "audio/ogg",
    "oga" => "audio/ogg",
    "wav" => "audio/wav",
    "m4a" => "audio/mp4",
    "mp4" => "video/mp4",
    "webm" => "video/webm",
    "woff" => "font/woff",
    "woff2" => "font/woff2",
    "ttf" => "font/ttf",
    "otf" => "font/otf",
  }.freeze
  DEFAULT_CONTENT_TYPE = "application/octet-stream"
  PUBLIC_ID_LENGTH = 21
  DISPLAY_NAME_MAX_LENGTH = 200
  STORAGE_PREFIX = "builds"
  PUBLIC_ID_ALPHABET = [*"0".."9", *"A".."Z", *"a".."z", "_", "-"].freeze
  PLAYER_GRANT_PURPOSE = "product_build_player"
  # Long enough for one play session. A refund or revoked access stops new sessions at once, and
  # running ones when the grant expires.
  PLAYER_GRANT_VALID_FOR = 12.hours
  PLAYER_SAVE_GRANT_PURPOSE = "product_build_player_save"
  # The play session a player page load started, for that page's heartbeat.
  PLAYER_HEARTBEAT_GRANT_PURPOSE = "product_build_player_heartbeat"
  # The save endpoint writes only into the buyer's own save, so its grant can outlive a play session:
  # a tab left open overnight can still save.
  PLAYER_SAVE_GRANT_VALID_FOR = 30.days
  PLAYER_DEMO_GRANT_PURPOSE = "product_build_player_demo"
  # Only pages check that the demo is still allowed, so a product made paid or banned keeps its other
  # files public until running grants expire.
  PLAYER_DEMO_GRANT_VALID_FOR = 1.hour
  DEMO_FEATURE = :product_build_demo
  # The origins that frame an X player card. CSP checks frame-ancestors against every ancestor, so the
  # demo's own page and the build's frame inside it both list them.
  DEMO_FRAME_ANCESTORS = %w[https://x.com https://*.x.com https://twitter.com https://*.twitter.com].freeze

  timestamp_state_fields :demo_selected

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

  def self.content_type_for(path) = CONTENT_TYPES[File.extname(path).delete_prefix(".").downcase] || DEFAULT_CONTENT_TYPE

  # Where the player serves this build's files from. The zip stays next to it as build.zip.
  def site_prefix
    "#{STORAGE_PREFIX}/#{product_id}/#{number}/#{SITE_DIRECTORY}"
  end

  # True once the zip has been unpacked into site_prefix. A build whose zip was rejected is not
  # ready: the seller has to upload a fixed zip as a new build.
  def site_ready? = site_unpacked_at.present?

  def live? = status == "live"

  def player_enabled? = product.build_player_enabled?

  # Whether buyers get a Play action for this build on the content page.
  def playable? = live? && site_ready? && player_enabled? && free_play_allowed?

  # A free build has no charge to check, so only a proven seller gets one. Pass the buyer's purchase
  # to also refuse a fully discounted one.
  def free_play_allowed?(purchase = nil)
    return true unless ContentModeration::GumroadImpersonation.unproven_seller?(product.user)
    return false if free_for_everyone?
    return true if purchase.nil?

    charged_purchases(purchase).any? { _1.is_test_purchase? || _1.price_cents.to_i.positive? }
  end

  # Whether anyone can play this build with no purchase, from the public demo page and its X player
  # card. The build the seller chose qualifies, unless it is what buyers of a paid product get: a
  # purchased version never becomes public. Without a choice, a free product's live build does, since
  # every buyer gets it for nothing anyway. The queries come last.
  def demo?
    return false unless Feature.active?(DEMO_FEATURE, product.user) && player_enabled? && site_ready? && on_sale?
    # A demo is public, so it needs a proven seller even when what buyers get is paid.
    return false if ContentModeration::GumroadImpersonation.unproven_seller?(product.user)
    return !purchased_version? if demo_selected?

    live? && free_for_everyone? && !product.product_builds.demo_selected.exists?
  end

  def self.free_product?(product)
    return false if product.rent_only? || product.is_recurring_billing || product.price_cents != 0

    variants = product.alive_variants
    variants.where("price_difference_cents > 0").none? &&
      VariantPrice.alive.is_buy.where(variant_id: variants.select(:id)).where("price_cents > 0").none?
  end

  # What buyers of a paid product get, which never becomes public.
  def purchased_version? = live? && !free_for_everyone?

  # The build the product's public demo plays, or nil when it has none. One query finds both candidates.
  def self.demo_for(product)
    build = product.product_builds.demo_selected.or(product.product_builds.live).min_by { _1.demo_selected? ? 0 : 1 }
    build if build&.demo?
  end

  # Makes this build the product's public demo, in place of any other. A build that was never promoted
  # has no site yet, so it is unpacked now.
  def select_as_demo!
    product.with_lock do
      product.product_builds.demo_selected.where.not(id:).update_all(demo_selected_at: nil, updated_at: Time.current)
      update_as_demo_selected!
    end
    ProductBuildUnpackJob.perform_async(id) unless site_ready?
    self
  end

  # The lock reloads the build, so a select that committed after it was loaded is still undone.
  def unselect_as_demo! = with_lock { update_as_not_demo_selected! }

  # A grant like player_grant, for the public demo: no purchase, so nothing to save to. The token is
  # the product's external id, which the demo route carries in place of a content-page token.
  def demo_grant
    self.class.player_grant_encryptor.encrypt_and_sign(
      { "token" => product.external_id, "build_id" => id, "site_prefix" => site_prefix },
      purpose: PLAYER_DEMO_GRANT_PURPOSE,
      expires_in: PLAYER_DEMO_GRANT_VALID_FOR,
    )
  end

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

  # A grant for the player page's heartbeat, naming the play session that page started. It carries
  # nothing else, so a stale page cannot extend another session.
  def player_heartbeat_grant(url_redirect_token:, purchase_id:, session_id:)
    self.class.player_grant_encryptor.encrypt_and_sign(
      { "token" => url_redirect_token, "purchase_id" => purchase_id, "session_id" => session_id },
      purpose: PLAYER_HEARTBEAT_GRANT_PURPOSE,
      expires_in: PLAYER_GRANT_VALID_FOR,
    )
  end

  # The grant's payload when it is valid and was issued for this content-page token, or nil.
  def self.verified_player_grant(grant, url_redirect_token:, purpose: PLAYER_GRANT_PURPOSE)
    payload = player_grant_encryptor.decrypt_and_verify(grant.to_s, purpose:)
    payload if payload.is_a?(Hash) && payload["token"] == url_redirect_token
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  # A grant for the save endpoint only: the content-page token and the purchase.
  def self.player_save_grant(url_redirect_token:, purchase_id:)
    player_grant_encryptor.encrypt_and_sign(
      { "token" => url_redirect_token, "purchase_id" => purchase_id },
      purpose: PLAYER_SAVE_GRANT_PURPOSE,
      expires_in: PLAYER_SAVE_GRANT_VALID_FOR,
    )
  end

  # Encrypted, not only signed: the grant is in the frame's URL, and it holds internal ids.
  # url_safe because it is a path segment.
  def self.player_grant_encryptor
    @player_grant_encryptor ||= ActiveSupport::MessageEncryptor.new(
      Rails.application.key_generator.generate_key("product_build_player_grant", ActiveSupport::MessageEncryptor.key_len),
      url_safe: true, serializer: JSON,
    )
  end

  # What the API and the editor's version history show of a build.
  def as_json(*)
    { id: public_id, number:, status:, byte_size:, created_at:, promoted_at:, demo: demo_selected?, unpack_error: site_unpack_error.presence }
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
    # The product page 404s for a banned product or a deleted seller, and a preorder delivers nothing yet.
    def on_sale?
      product.published? && !product.banned? && !product.is_in_preorder_state && !product.user.deleted? && !product.user.suspended?
    end

    # Free only when a buyer of any version can buy it for nothing (BaseVariant#free?, for all versions at
    # once). A rental-only product has no buy price.
    def free_for_everyone? = self.class.free_product?(product)

    # The purchases that could hold this one's charge. A purchase does not always carry the money on
    # its own row: a bundle component is written with a price of 0 because the bundle purchase was the
    # one charged (Purchase::CreateBundleProductPurchaseService), and a gift receiver's is 0 because
    # the gifter paid. Reading only the row in hand would refuse a paid bundle or gift.
    #
    # In practice the call above rarely gets this far for those two: the charged row belongs to the
    # same seller (BundleProductPurchase checks it), so it is a paid sale and the seller counts as
    # proven at the first return. Following the money anyway keeps the decision about what was paid
    # rather than about a definition of "proven" that the rest of the codebase does not apply
    # uniformly (see CreatorHomePresenter, which excludes bundle component purchases from has_sale).
    def charged_purchases(purchase)
      charged = [purchase]
      charged << purchase.bundle_purchase if purchase.is_bundle_product_purchase?
      charged << purchase.gift_received&.gifter_purchase if purchase.is_gift_receiver_purchase?
      charged.compact
    end

    def set_public_id
      self.public_id ||= Array.new(PUBLIC_ID_LENGTH) { PUBLIC_ID_ALPHABET[SecureRandom.random_number(PUBLIC_ID_ALPHABET.size)] }.join
    end

    # Buyers only see files embedded in content pages, so the live zip goes on the first page of
    # the product (or of each variant) and the superseded one is removed everywhere.
    def swap_file_embed(old_file, new_file)
      per_variant = !product.has_product_level_rich_content?
      # A product with no page yet (a first upload from the editor) gets one holding the zip and any
      # files it already had, as a variant without pages does below.
      if !per_variant && product.alive_rich_contents.none?
        existing = product.product_files.alive.where.not(id: [old_file&.id, new_file.id].compact).in_order
        product.alive_rich_contents.create!(description: (existing.to_a + [new_file]).map { file_embed_node(_1) })
        return
      end
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
