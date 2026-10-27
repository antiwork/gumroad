# frozen_string_literal: true

require "digest"

# A partner application's request to move one of its users' catalogs to Gumroad.
#
# The partner sends the products, and gets back a one-time onboarding link. The creator opens the
# link, logs in or signs up, and claims the migration. The claim links the creator to the partner's
# user ID and imports the products as drafts. Only a SHA-256 digest of the link's code is stored.
class PartnerMigration < ApplicationRecord
  EXPIRES_IN = 7.days
  MAX_PRODUCTS = 500
  MAX_EXTERNAL_USER_ID_LENGTH = 255
  MAX_NAME_LENGTH = 255
  MAX_FAILURE_REASON_LENGTH = 255
  MAX_FILES_PER_PRODUCT = 50
  # The product editor's limit (TagSelector).
  MAX_TAGS_PER_PRODUCT = 10
  # Without SKUs, checkout offers only the first variant category of a digital product.
  MAX_VARIANT_CATEGORIES = 1
  MAX_VARIANTS_PER_CATEGORY = 20
  MAX_CODE_GENERATION_ATTEMPTS = 3

  STATUS_PENDING = "pending"
  STATUS_CLAIMED = "claimed"
  STATUS_COMPLETED = "completed"
  STATUS_FAILED = "failed"
  STATUSES = [STATUS_PENDING, STATUS_CLAIMED, STATUS_COMPLETED, STATUS_FAILED].freeze

  class ClaimError < StandardError; end
  class CatalogConflict < StandardError; end

  belongs_to :oauth_application
  belongs_to :user, optional: true

  validates :external_user_id, presence: true, length: { maximum: MAX_EXTERNAL_USER_ID_LENGTH }
  validates :code_digest, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :expires_at, presence: true

  def self.create_for!(oauth_application:, external_user_id:, products:)
    attempts = 0

    begin
      attempts += 1
      code = SecureRandom.urlsafe_base64(32)
      oauth_application.with_lock do
        migration = where(oauth_application:, external_user_id:).order(:id).first
        if migration
          if !migration.pending? && catalog_identity(migration.products) != catalog_identity(products)
            raise CatalogConflict, "This seller already has an export. Keep the same products and file order when refreshing download URLs."
          end
          migration.update!(products:, code_digest: digest(code), expires_at: EXPIRES_IN.from_now)
        else
          migration = create!(oauth_application:, external_user_id:, products:, code_digest: digest(code), expires_at: EXPIRES_IN.from_now)
        end
        [migration, code]
      end
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_CODE_GENERATION_ATTEMPTS
      raise
    end
  end

  def self.find_by_code(code)
    return if code.blank?

    find_by(code_digest: digest(code))
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.catalog_identity(products)
    products.map do |product|
      product.except("files", "covers", "thumbnail_url").merge(
        "files" => product["files"].map { _1.except("url") },
        "covers" => product["covers"].size,
        "thumbnail" => product["thumbnail_url"].present?,
      )
    end
  end

  def self.record_first_publication(product)
    where(user_id: product.user_id).find_each do |migration|
      next unless migration.results.to_h.values.any? { _1["product_id"] == product.external_id }

      PartnerSeller.where(oauth_application_id: migration.oauth_application_id, user_id: product.user_id, external_user_id: migration.external_user_id)
                   .where("migrated_at IS NULL OR migrated_at > ?", product.first_published_at)
                   .update_all(migrated_at: product.first_published_at)
    end
  end

  # Returns [products, nil] with only the supported keys, or [nil, error message].
  def self.normalize_products(raw_products)
    return [nil, "products must be an array with 1 to #{MAX_PRODUCTS} items."] unless raw_products.is_a?(Array) && raw_products.size.between?(1, MAX_PRODUCTS)

    products = raw_products.each_with_index.map do |raw, index|
      product, error = normalize_product(raw)
      return [nil, "products[#{index}]: #{error}"] if error

      product
    end

    [products, nil]
  end

  def self.normalize_product(raw)
    return [nil, "must be an object."] unless raw.respond_to?(:key?)
    return [nil, "name must be a string with 1 to #{MAX_NAME_LENGTH} characters."] unless string?(raw[:name]) && raw[:name].strip.length.between?(1, MAX_NAME_LENGTH)
    return [nil, "description must be a string."] unless raw[:description].nil? || string?(raw[:description])
    return [nil, "price must be a whole number of cents, 0 or more."] unless raw[:price].is_a?(Integer) && raw[:price] >= 0
    return [nil, "price must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents."] if raw[:price] > BasePrice::Shared::MAX_PRICE_CENTS

    currency = raw[:price_currency_type].nil? ? "usd" : raw[:price_currency_type].to_s.downcase
    return [nil, "price_currency_type is not a supported currency."] unless CURRENCY_CHOICES.key?(currency)
    min_price = CURRENCY_CHOICES[currency]["min_price"]
    return [nil, "price must be 0 or at least #{min_price} cents in #{currency}."] unless raw[:price].zero? || raw[:price] >= min_price
    return [nil, "taxonomy_id is not a known category."] unless raw[:taxonomy_id].nil? || (raw[:taxonomy_id].is_a?(Integer) && Taxonomy.exists?(id: raw[:taxonomy_id]))

    tags = raw[:tags].nil? ? [] : raw[:tags]
    return [nil, "tags must be an array of up to #{MAX_TAGS_PER_PRODUCT} strings."] unless tags.is_a?(Array) && tags.size <= MAX_TAGS_PER_PRODUCT && tags.all? { string?(_1) }
    # Product#tag! cannot save the same tag twice, so clean them up as Tag#clean_name does first.
    tags = unique_tag_names(tags.map { _1.downcase.strip.gsub(/[[:space:]]+/, " ") }.uniq)
    tag_error = tags.lazy.filter_map { tag_error(_1) }.first
    return [nil, "tags: #{tag_error}"] if tag_error

    files = raw[:files].nil? ? [] : raw[:files]
    return [nil, "files must be an array with up to #{MAX_FILES_PER_PRODUCT} items."] unless files.is_a?(Array) && files.size <= MAX_FILES_PER_PRODUCT
    return [nil, "each file needs an https url and an optional display_name string."] unless files.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) && (_1[:display_name].nil? || string?(_1[:display_name])) }
    return [nil, "file display_name must have at most #{MAX_NAME_LENGTH} characters."] if files.any? { _1[:display_name].to_s.length > MAX_NAME_LENGTH }

    covers = raw[:covers].nil? ? [] : raw[:covers]
    return [nil, "covers must be an array with up to #{Link::MAX_PREVIEW_COUNT} items."] unless covers.is_a?(Array) && covers.size <= Link::MAX_PREVIEW_COUNT
    return [nil, "each cover needs an https url."] unless covers.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) }
    return [nil, "thumbnail_url must be an https URL."] unless raw[:thumbnail_url].nil? || https_url?(raw[:thumbnail_url])

    variant_categories, error = normalize_variant_categories(raw[:variant_categories])
    return [nil, error] if error
    if variant_categories.any? { _1["variants"].any? { |variant| raw[:price] + variant["price_difference_cents"] > BasePrice::Shared::MAX_PRICE_CENTS } }
      return [nil, "the product price plus each variant price difference must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents."]
    end

    [{
      "name" => raw[:name].strip,
      "description" => raw[:description],
      "price" => raw[:price],
      "price_currency_type" => currency,
      "taxonomy_id" => raw[:taxonomy_id],
      "tags" => tags,
      "files" => files.map { { "url" => _1[:url], "display_name" => _1[:display_name] } },
      "covers" => covers.map { { "url" => _1[:url] } },
      "thumbnail_url" => raw[:thumbnail_url],
      "variant_categories" => variant_categories,
    }, nil]
  end

  def self.normalize_variant_categories(raw_categories)
    return [[], nil] if raw_categories.nil?
    return [nil, "variant_categories must be an array with up to #{MAX_VARIANT_CATEGORIES} item."] unless raw_categories.is_a?(Array) && raw_categories.size <= MAX_VARIANT_CATEGORIES

    categories = raw_categories.map do |category|
      return [nil, "each variant category needs a title string and 1 to #{MAX_VARIANTS_PER_CATEGORY} variants."] unless category.respond_to?(:key?) && string?(category[:title]) && category[:variants].is_a?(Array) && category[:variants].size.between?(1, MAX_VARIANTS_PER_CATEGORY)
      return [nil, "variant category title must have 1 to #{MAX_NAME_LENGTH} characters."] unless category[:title].strip.length.between?(1, MAX_NAME_LENGTH)

      variants = category[:variants].map do |variant|
        return [nil, "each variant needs a name string and a whole number price_difference_cents from 0 to #{BasePrice::Shared::MAX_PRICE_CENTS}."] unless variant.respond_to?(:key?) && string?(variant[:name]) && (variant[:price_difference_cents].nil? || (variant[:price_difference_cents].is_a?(Integer) && variant[:price_difference_cents].between?(0, BasePrice::Shared::MAX_PRICE_CENTS)))
        return [nil, "variant name must have 1 to #{MAX_NAME_LENGTH} characters."] unless variant[:name].strip.length.between?(1, MAX_NAME_LENGTH)

        { "name" => variant[:name].strip, "price_difference_cents" => variant[:price_difference_cents] || 0 }
      end

      { "title" => category[:title].strip, "variants" => variants }
    end

    [categories, nil]
  end

  def self.string?(value) = value.is_a?(String)

  # Keeps the first of the names that tags.name treats as equal. Its collation matches "café" with
  # "cafe" and "straße" with "strasse", which Ruby cannot reproduce, so MySQL groups them.
  def self.unique_tag_names(names)
    return names if names.size < 2

    collation = Tag.columns_hash.fetch("name").collation
    raise ArgumentError, "Unexpected collation #{collation.inspect}" unless collation.match?(/\A\w+\z/)

    rows = Array.new(names.size, "SELECT ? AS position, ? AS name").join(" UNION ALL ")
    sql = sanitize_sql_array(["SELECT MIN(position) FROM (#{rows}) names GROUP BY name COLLATE #{collation}", *names.each_with_index.flat_map { [_2, _1] }])
    connection.select_values(sql).map(&:to_i).sort.map { names[_1] }
  end

  # Tag's own name rules, without its uniqueness check: the import reuses an existing tag.
  def self.tag_error(name)
    tag = Tag.new(name:)
    Tag.validators_on(:name).grep_v(ActiveRecord::Validations::UniquenessValidator).each { _1.validate(tag) }
    tag.errors[:name].first
  end

  def self.https_url?(value)
    return false unless value.is_a?(String)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
  private_class_method :catalog_identity, :normalize_product, :normalize_variant_categories, :string?, :unique_tag_names, :tag_error, :https_url?

  def pending? = status == STATUS_PENDING
  def expired?(at = Time.current) = expires_at <= at

  def claimable?
    pending? && !expired? && oauth_application.alive? && oauth_application.is_partner?
  end

  # The same creator can claim again while the import has not finished, so a failed enqueue can be
  # retried from the confirmation page. The job skips the products that it already imported.
  def claimable_by?(claimer)
    claimable? || (status == STATUS_CLAIMED && user_id == claimer.id)
  end

  # Links `claimer` to the partner's user ID, then starts the import. Raises ClaimError with a
  # message for the creator when the link was used, expired, or belongs to a different account.
  def claim!(claimer)
    raise ClaimError, "This account cannot import products." unless claimer.account_active?

    oauth_application.with_lock do
      with_lock do
        raise ClaimError, "This link is invalid or expired." unless claimable_by?(claimer)
        next if status == STATUS_CLAIMED

        link_partner_seller!(claimer)
        update!(user: claimer, status: STATUS_CLAIMED, claimed_at: Time.current)
      end
    end

    PartnerMigrationImportJob.perform_async(id)
  end

  def retry!(requester)
    raise ClaimError, "This import is not available to this account." unless user_id == requester.id && requester.account_active?
    raise ClaimError, "This partner connection is no longer active." unless oauth_application.alive? && oauth_application.is_partner? && oauth_application.partner_sellers.alive.exists?(user_id: requester.id, external_user_id:)

    with_lock do
      restarting = status != STATUS_CLAIMED
      if restarting
        update!(results: results.to_h.reject { |_index, result| result.key?("error") }, status: STATUS_CLAIMED, failure_reason: nil, completed_at: nil)
      end
      if PartnerMigrationImportJob.perform_async(id).nil? && restarting
        raise ClaimError, "The previous import is still finishing. Wait a moment, then try again."
      end
    end
  end

  def progress
    recorded_results = results.to_h.values
    imported = recorded_results.count { _1["product_id"].present? }
    failed = recorded_results.count { _1["error"].present? }
    { total: products.size, imported:, failed:, remaining: products.size - imported - failed }
  end

  def status_id
    signed_id(purpose: :partner_migration)
  end

  private
    def link_partner_seller!(claimer)
      partner_sellers = oauth_application.partner_sellers
      by_external_user = partner_sellers.find_by(external_user_id:)
      by_user = partner_sellers.find_by(user: claimer)

      if by_external_user&.user_id.present? && by_external_user.user_id != claimer.id
        raise ClaimError, "This #{oauth_application.name} account is already linked to a different Gumroad account."
      end
      if by_user.present? && by_user.external_user_id != external_user_id
        raise ClaimError, "Your Gumroad account is already linked to a different #{oauth_application.name} account."
      end

      partner_seller = by_user || partner_sellers.build(user: claimer, external_user_id:)
      partner_seller.deleted_at = nil
      partner_seller.save!
    end
end
