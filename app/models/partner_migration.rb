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
      migration = create!(oauth_application:, external_user_id:, products:, code_digest: digest(code), expires_at: EXPIRES_IN.from_now)
      [migration, code]
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

    covers = raw[:covers].nil? ? [] : raw[:covers]
    return [nil, "covers must be an array with up to #{Link::MAX_PREVIEW_COUNT} items."] unless covers.is_a?(Array) && covers.size <= Link::MAX_PREVIEW_COUNT
    return [nil, "each cover needs an https url."] unless covers.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) }
    return [nil, "thumbnail_url must be an https URL."] unless raw[:thumbnail_url].nil? || https_url?(raw[:thumbnail_url])

    variant_categories, error = normalize_variant_categories(raw[:variant_categories])
    return [nil, error] if error

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

      variants = category[:variants].map do |variant|
        return [nil, "each variant needs a name string and a whole number price_difference_cents from 0 to #{BasePrice::Shared::MAX_PRICE_CENTS}."] unless variant.respond_to?(:key?) && string?(variant[:name]) && (variant[:price_difference_cents].nil? || (variant[:price_difference_cents].is_a?(Integer) && variant[:price_difference_cents].between?(0, BasePrice::Shared::MAX_PRICE_CENTS)))

        { "name" => variant[:name], "price_difference_cents" => variant[:price_difference_cents] || 0 }
      end

      { "title" => category[:title], "variants" => variants }
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
  private_class_method :normalize_product, :normalize_variant_categories, :string?, :unique_tag_names, :tag_error, :https_url?

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
      partner_seller.migrated_at ||= Time.current
      partner_seller.save!
    end
end
