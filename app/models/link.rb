# frozen_string_literal: true

require "zip/zipfilesystem"

class Link < ApplicationRecord
  has_paper_trail
  # Moving the definition of these flags will cause an error.
  include FlagShihTzu
  include ActionView::Helpers::SanitizeHelper
  has_flags 1 => :product_refund_policy_enabled,
            2 => :is_recurring_billing,
            3 => :free_trial_enabled,
            4 => :is_in_preorder_state,
            5 => :archived,
            6 => :is_duplicating,
            7 => :is_licensed,
            8 => :is_physical,
            9 => :skus_enabled,
            10 => :block_access_after_membership_cancellation,
            11 => :is_price_tax_exclusive_DEPRECATED,
            12 => :should_include_last_post,
            13 => :from_bundle_marketing,
            14 => :quantity_enabled,
            15 => :has_outdated_purchases,
            16 => :is_adult,
            17 => :display_product_reviews,
            18 => :allow_double_charges,
            19 => :is_tiered_membership,
            20 => :should_show_all_posts,
            21 => :is_multiseat_license,
            22 => :should_show_sales_count,
            23 => :is_epublication,
            24 => :transcode_videos_on_purchase,
            25 => :has_same_rich_content_for_all_variants,
            26 => :is_bundle,
            27 => :purchasing_power_parity_disabled,
            28 => :is_collab,
            29 => :is_unpublished_by_admin,
            30 => :community_chat_enabled,
            31 => :DEPRECATED_excluded_from_mobile_app_discover,
            32 => :moderated_by_iffy,
            33 => :hide_sold_out_variants,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  include ProductsHelper, PreorderHelper, CurrencyHelper, SocialShareUrlHelper, Product::Stats, Product::Preview,
          Product::Validations, Product::Caching, Product::NativeTypeTemplates, Product::Recommendations,
          Product::Prices, Product::Shipping, Product::Searchable, Product::Tags, Product::Taxonomies,
          Product::ReviewStat, Product::Utils, ActionView::Helpers::SanitizeHelper,
          ActionView::Helpers::NumberHelper, Mongoable, TimestampScopes, ExternalId,
          WithFileProperties, JsonData, Deletable, WithProductFiles, WithCdnUrl, MaxPurchaseCount,
          Integrations, Product::StaffPicked, RichContents, Product::Sorting, Product::CreationLimit

  has_cdn_url :description

  TIME_EVENTS_TABLE_CREATED = Time.zone.parse("2012-10-11 23:35:41")

  PURCHASE_PROPERTIES = ["updated_at"].freeze
  MAX_ALLOWED_FILE_SIZE_FOR_SEND_TO_KINDLE = 15_500_000.bytes

  METADATA_CACHE_NAMESPACE = :product_metadata_cache
  REQUIRE_CAPTCHA_FOR_SELLERS_YOUNGER_THAN = 6.months

  # Tax categories: https://developers.taxjar.com/api/reference/#get-list-tax-categories
  # Categories mapping choices: https://www.notion.so/gumroad/System-support-for-US-sales-tax-collection-on-Gumroad-MPF-sales-9fa88740bf3c4453b476b7fa0a7af1e7#3404578361074b4ca24a6fb63464f522
  NATIVE_TYPES_TO_TAX_CODE = {
    "digital" => "31000",
    "course" => "86132000A0002",
    "ebook" => "31000",
    "newsletter" => "55111516A0310",
    "membership" => "55111516A0310",
    "podcast" => "55111516A0310",
    "audiobook" => "31000",
    "physical" => nil,
    "bundle" => "55111500A9220",
    "commission" => nil,
    "call" => nil,
    "coffee" => nil,
  }.freeze
  NATIVE_TYPES = NATIVE_TYPES_TO_TAX_CODE.keys.freeze
  NATIVE_TYPES.each do |native_type|
    self.const_set("NATIVE_TYPE_#{native_type.upcase}", native_type)
  end
  SERVICE_TYPES = [NATIVE_TYPE_COMMISSION, NATIVE_TYPE_CALL, NATIVE_TYPE_COFFEE].freeze
  LEGACY_TYPES = ["podcast", "newsletter", "audiobook"].freeze

  DEFAULT_BOOSTED_DISCOVER_FEE_PER_THOUSAND = 300

  belongs_to :user, optional: true
  has_many :prices
  has_many :alive_prices, -> { alive }, class_name: "Price"
  has_one :installment_plan, -> { alive }, class_name: "ProductInstallmentPlan"
  has_many :sales, class_name: "Purchase"
  has_many :orders, through: :sales, source: :order
  has_many :sold_calls, through: :sales, source: :call
  has_many :asset_previews
  has_one :thumbnail, foreign_key: "product_id"
  has_one :thumbnail_alive, -> { alive }, class_name: "Thumbnail", foreign_key: "product_id"
  has_many :display_asset_previews, -> { alive.in_order }, class_name:  "AssetPreview"
  has_many :gifts
  has_many :url_redirects
  has_many :variant_categories
  has_many :variant_categories_alive, -> { alive }, class_name: "VariantCategory"
  has_many :variants, through: :variant_categories, class_name: "Variant"
  has_many :alive_variants, through: :variant_categories_alive, source: :alive_variants
  has_many :tier_categories, -> { alive.is_tier_category }, class_name: "VariantCategory"
  has_many :tiers, through: :tier_categories, class_name: "Variant"
  has_one :tier_category, -> { alive.is_tier_category }, class_name: "VariantCategory"
  has_one :default_tier, through: :tier_category
  has_many :skus
  has_many :skus_alive_not_default, -> { alive.not_is_default_sku }, class_name: "Sku"
  has_many :installments
  has_many :subscriptions
  has_and_belongs_to_many :offer_codes, join_table: "offer_codes_products", foreign_key: "product_id"
  has_many :transcoded_videos
  has_many :imported_customers
  has_many :licenses
  has_one :preorder_link
  belongs_to :affiliate_application, class_name: "OauthApplication", optional: true
  has_many :affiliate_credits
  has_many :comments, as: :commentable
  has_many :workflows
  has_many :dropbox_files
  has_many :shipping_destinations
  has_many :product_affiliates
  has_many :affiliates, through: :product_affiliates
  has_many :direct_affiliates, -> { direct_affiliates }, through: :product_affiliates, source: :affiliate
  has_many :global_affiliates, -> { global_affiliates }, through: :product_affiliates, source: :affiliate
  has_many :confirmed_collaborators, -> { confirmed_collaborators }, through: :product_affiliates, source: :affiliate
  has_many :pending_or_confirmed_collaborators, -> { pending_or_confirmed_collaborators }, through: :product_affiliates, source: :affiliate
  has_many :self_service_affiliate_products, foreign_key: :product_id
  has_many :third_party_analytics
  has_many :alive_third_party_analytics, -> { alive }, class_name: "ThirdPartyAnalytic"
  # info of purchases this product has recommended
  has_many :recommended_purchase_infos, class_name: "RecommendedPurchaseInfo", foreign_key: :recommended_by_link_id
  # info of recommended purchases that have bought this product
  has_many :recommended_by_purchase_infos, class_name: "RecommendedPurchaseInfo", foreign_key: :recommended_link_id
  has_one :product_review_stat
  has_many :product_reviews
  has_many :product_integrations, class_name: "ProductIntegration", foreign_key: :product_id
  has_many :live_product_integrations, -> { alive }, class_name: "ProductIntegration", foreign_key: :product_id
  has_many :active_integrations, through: :live_product_integrations, source: :integration
  has_many :product_cached_values, foreign_key: :product_id
  has_one :upsell, -> { upsell.alive }, foreign_key: :product_id
  has_one :available_upsell, -> { upsell.available_to_customers },
          class_name: "Upsell", foreign_key: :product_id
  has_many :available_upsell_variants, through: :available_upsell, source: :upsell_variants
  has_many :available_cross_sells, ->(link) {
    includes(:selected_products)
      .where(selected_products: { id: link.id })
      .or(where(universal: true))
  }, through: :user, source: :available_cross_sells
  has_and_belongs_to_many :custom_fields, join_table: "custom_fields_products", foreign_key: "product_id"
  has_one :product_refund_policy, foreign_key: "product_id"
  has_one :staff_picked_product, foreign_key: "product_id"
  has_one :custom_domain, -> { alive }, foreign_key: "product_id"
  has_many :bundle_products, foreign_key: "bundle_id", inverse_of: :bundle
  has_many :wishlist_products, foreign_key: "product_id"
  has_many :call_availabilities, foreign_key: "call_id"
  has_one :call_limitation_info, foreign_key: "call_id"
  has_many :seller_profile_sections, foreign_key: :product_id
  has_many :public_files, as: :resource
  has_many :alive_public_files, -> { alive }, class_name: "PublicFile", as: :resource
  has_many :communities, as: :resource, dependent: :destroy
  has_one :active_community, -> { alive }, class_name: "Community", as: :resource

  before_validation :associate_price, on: :create
  before_validation :set_unique_permalink
  before_validation :release_custom_permalink_if_possible, if: :custom_permalink_changed?
  validates :user, presence: true
  validates :name, presence: true, length: { maximum: 255 }
  # Keep in sync with Product::BulkUpdateSupportEmailService.
  validates :support_email, email_format: true, not_reserved_email_domain: true, allow_nil: true
  validates :default_price_cents, presence: true
  validates :unique_permalink, presence: true, uniqueness: { case_sensitive: false }, format: { with: /\A[a-zA-Z_]+\z/ }
  validates :custom_permalink, format: { with: /\A[a-zA-Z0-9_-]+\z/ }, uniqueness: { scope: :user_id, case_sensitive: false }, allow_nil: true, allow_blank: true
  validate :suggested_price_greater_than_price
  validate :duration_multiple_of_price_options
  validate :custom_and_unique_permalink_uniqueness
  validate :custom_permalink_of_licensed_product, if: :custom_permalink_or_is_licensed_changed?
  validate :max_purchase_count_is_greater_than_or_equal_to_inventory_sold
  validate :free_trial_only_enabled_if_recurring_billing
  validates :native_type, inclusion: { in: NATIVE_TYPES }
  validates :discover_fee_per_thousand, inclusion: { in: [100, *(300..1000)], message: "must be between 30% and 100%" }
  validates :free_trial_duration_unit, presence: true, if: :free_trial_enabled?
  # Only allow "1 week" and "1 month" free trials for now
  validates :free_trial_duration_amount, presence: true,
                                         numericality: { only_integer: true,
                                                         equal_to: 1,
                                                         allow_nil: true },
                                         if: ->(link) { link.free_trial_enabled? && (!link.persisted? || link.free_trial_duration_amount_changed?) }
  validate :price_must_be_within_range
  validate :require_shipping_for_physical
  validate :valid_tier_version_structure, if: :is_tiered_membership, on: :update
  validate :calls_must_have_at_least_one_duration, on: :update
  validate :alive_category_variants_presence, on: :update
  validate :content_has_no_adult_keywords, if: -> { description_changed? || name_changed? }
  validate :custom_view_content_button_text_length
  validates_presence_of :filetype
  validates_presence_of :filegroup
  validate :bundle_is_not_in_bundle, if: :is_bundle_changed?
  validate :published_bundle_must_have_at_least_one_product, on: :update
  validate :user_is_eligible_for_service_products, on: :create, if: :is_service?
  validate :commission_price_is_valid, if: -> { native_type == Link::NATIVE_TYPE_COMMISSION }
  validate :one_coffee_per_user, on: :create, if: -> { native_type == Link::NATIVE_TYPE_COFFEE }
  validate :quantity_enabled_state_is_allowed

  validates_associated :installment_plan, message: -> (link, _) { link.installment_plan.errors.full_messages.first }

  before_save :downcase_filetype
  before_save :remove_xml_tags
  after_save :set_customizable_price
  after_update :invalidate_cache, if: ->(link) { (link.saved_changes.keys - PURCHASE_PROPERTIES).present? }
  after_update :create_licenses_for_existing_customers,
               if: ->(link) { link.saved_change_to_is_licensed? && link.is_licensed? }
  after_update :delete_unused_prices, if: :saved_change_to_purchase_type?
  after_update :reset_moderated_by_iffy_flag, if: :saved_change_to_description?
  after_save :queue_iffy_ingest_job_if_unpublished_by_admin

  enum subscription_duration: %i[monthly yearly quarterly biannually every_two_years]
  enum purchase_type: %i[buy_only rent_only buy_and_rent] # Indicates whether this product can be bought or rented or both.
  enum free_trial_duration_unit: %i[week month]

  attr_json_data_accessor :excluded_sales_tax_regions, default: -> { [] }
  attr_json_data_accessor :sections, default: -> { [] }
  attr_json_data_accessor :main_section_index, default: -> { 0 }

  scope :alive,                           -> { where(purchase_disabled_at: nil, banned_at: nil, deleted_at: nil) }
  scope :visible,                         -> { where(deleted_at: nil) }
  scope :visible_and_not_archived,        -> { visible.not_archived }
  scope :by_user,                         ->(user) { where(user.present? ? { user_id: user.id } : "1 = 1") }
  scope :by_general_permalink,            ->(permalink) { where("unique_permalink = ? OR custom_permalink = ?", permalink, permalink) }
  scope :by_unique_permalinks,            ->(permalinks) { where("unique_permalink IN (?)", permalinks) }
  scope :has_paid_sales,                  lambda {
    distinct.joins(:sales).where("purchases.purchase_state = 'successful' AND purchases.price_cents > 0" \
    " AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)")
  }
  scope :not_draft,                       -> { where(draft: false) }
  scope :has_paid_sales_between, lambda { |begin_time, end_time|
    distinct.joins(:sales).where(["purchases.purchase_state = 'successful' AND purchases.price_cents > 0 AND purchases.created_at > ?" \
    "AND purchases.created_at < ? AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)", begin_time, end_time])
  }
  scope :membership, -> { is_recurring_billing }
  scope :non_membership, -> { not_is_recurring_billing }
  scope :with_min_price, ->(min_price) { min_price.present? ? distinct.joins(:prices).where("prices.deleted_at IS NULL AND prices.price_cents >= ?", min_price) : where("1 = 1") }

  # !! MySQL ONLY !! Retrieves products in the order specified by the ids array. Relies on MySQL FIELD.
  scope :ordered_by_ids, ->(ids) { order([Arel.sql("FIELD(links.id, ?)"), ids]) }

  scope :with_direct_affiliates, -> { left_outer_joins(:direct_affiliates) }
  scope :for_affiliate_user, ->(affiliate_user_id) { where(affiliates: { affiliate_user_id: }) }
  scope :with_user_category, ->(category_ids) {
    distinct.joins(user: [:categories]).where(categories: category_ids)
  }

  scope :collabs_as_collaborator, ->(user) do
    joins(product_affiliates: :affiliate)
      .is_collab
      .where(affiliates: { affiliate_user: user })
      .merge(Collaborator.invitation_accepted.alive)
  end
  scope :collabs_as_seller_or_collaborator, ->(user) do
    joins(product_affiliates: :affiliate)
      .is_collab
      .where("affiliates.seller_id = :user_id OR affiliates.affiliate_user_id = :user_id", user_id: user.id)
      .merge(Collaborator.invitation_accepted.alive)
  end

  scope :for_balance_page, ->(user) do
    products_as_seller = Link.where(user: user)
    collabs_as_collaborator = Link.collabs_as_collaborator(user)

    subquery_sqls = [products_as_seller, collabs_as_collaborator].map(&:to_sql)
    from("(" + subquery_sqls.join(" UNION ") + ") AS #{table_name}")
  end

  scope :not_call, -> { where.not(native_type: NATIVE_TYPE_CALL) }
  scope :can_be_bundle, -> { non_membership.not_call.where.missing(:variant_categories_alive).or(is_bundle) }

  scope :with_latest_product_cached_values, ->(user_id:) {
    products_ids_sql = Link.where(user_id:).select(:id).to_sql # redundant subquery for performance
    cte_join_sql = <<~SQL.squish
      INNER JOIN (
        SELECT product_id, MAX(id) AS max_id
        FROM product_cached_values
        WHERE product_id IN (#{products_ids_sql})
        GROUP BY product_id
      ) latest ON product_cached_values.product_id = latest.product_id AND product_cached_values.id = latest.max_id
    SQL
    join_sql = <<~SQL.squish
      LEFT JOIN latest_product_cached_values ON latest_product_cached_values.product_id = links.id
    SQL

    with(latest_product_cached_values: ProductCachedValue.joins(cte_join_sql)).joins(join_sql)
  }

  scope :eligible_for_content_upsells, -> { visible_and_not_archived.not_is_tiered_membership }

  alias super_as_json as_json

  before_create :set_default_discover_fee_per_thousand
  after_create :initialize_tier_if_needed
  after_create :add_to_profile_sections
  after_create :initialize_suggested_amount_if_needed!
  after_create :initialize_call_limitation_info_if_needed!
  after_create :initialize_duration_variant_category_for_calls!

  def set_default_discover_fee_per_thousand
    self.discover_fee_per_thousand = DEFAULT_BOOSTED_DISCOVER_FEE_PER_THOUSAND if user.discover_boost_enabled?
  end

  def initialize_tier_if_needed
    if is_tiered_membership
      self.subscription_duration ||= BasePrice::Recurrence::DEFAULT_TIERED_MEMBERSHIP_RECURRENCE
      category = variant_categories.create!(title: "Tier")
      category.variants.create!(name: "Untitled")

      initialize_default_tier_prices!
    end
  end

  def initialize_default_tier_prices!
    if default_tier.present?
      # create a default price for the default tier
      initial_price_cents = read_attribute(:price_cents) || 0
      initial_price_cents = initial_price_cents * 100.0 if single_unit_currency?
      default_tier.save_recurring_prices!(
        subscription_duration.to_s => {
          enabled: true,
          price: formatted_dollar_amount(initial_price_cents)
        }
      )
    end
  end

  def initialize_suggested_amount_if_needed!
    return unless native_type == NATIVE_TYPE_COFFEE
    category = variant_categories.create!(title: "Suggested Amounts")
    category.variants.create!(name: "", price_difference_cents: price_cents)
    update!(price_cents: 0, customizable_price: true)
  end

  def initialize_call_limitation_info_if_needed!
    return unless native_type == NATIVE_TYPE_CALL
    create_call_limitation_info!
  end

  def initialize_duration_variant_category_for_calls!
    return unless native_type == NATIVE_TYPE_CALL
    variant_categories.create!(title: "Duration")
  end

  def banned?
    banned_at.present?
  end

  def alive?
    purchase_disabled_at.nil? && banned_at.nil? && deleted_at.nil?
  end

  def published?
    deleted_at.nil? && purchase_disabled_at.nil? && !draft
  end

  def compliance_blocked(ip)
    return false if ip.blank?

    country_code = GeoIp.lookup(ip)&.country_code
    country_code.present? && Compliance::Countries.blocked?(country_code)
  end

  def admins_can_generate_url_redirects?
    product_files.alive.exists?
  end

  def rentable?
    rent_only? || buy_and_rent?
  end

  def buyable?
    buy_only? || buy_and_rent?
  end

  def delete!
    mark_deleted!
    custom_domain&.mark_deleted!
    alive_public_files.update_all(scheduled_for_deletion_at: 10.minutes.from_now)
    CancelSubscriptionsForProductWorker.perform_in(10.minutes, id) if subscriptions.active.present?
    DeleteProductFilesWorker.perform_in(10.minutes, id)
    DeleteProductRichContentWorker.perform_in(10.minutes, id)
    DeleteProductFilesArchivesWorker.perform_in(10.minutes, id, nil)
    DeleteWishlistProductsJob.perform_in(10.minutes, id)
  end

  def publish!
    enforce_shipping_destinations_presence!
    enforce_user_email_confirmation!
    enforce_merchant_account_exits_for_new_users!

    if auto_transcode_videos?
      transcode_videos!
    else
      enable_transcode_videos_on_purchase!
    end

    self.purchase_disabled_at = nil
    self.deleted_at = nil
    self.draft = false
    save!

    user.direct_affiliates.alive.apply_to_all_products.each do |affiliate|
      unless affiliate.products.include?(self)
        affiliate.products << self
        AffiliateMailer.notify_direct_affiliate_of_new_product(affiliate.id, id).deliver_later
      end
    end
  end

  def unpublish!(is_unpublished_by_admin: false)
    self.purchase_disabled_at ||= Time.current
    self.is_unpublished_by_admin = is_unpublished_by_admin
    save!
  end

  def publishable?
    user.can_publish_products?
  end

  def has_filegroup?(filegroup)
    alive_product_files.map(&:filegroup).include?(filegroup)
  end

  def has_filetype?(filetype)
    alive_product_files.map(&:filetype).include?(filetype)
  end

  def has_stampable_pdfs?
    alive_product_files.any?(&:must_be_pdf_stamped?)
  end

  def streamable?
    has_filegroup?("video")
  end

  def require_captcha?
    user.created_at > REQUIRE_CAPTCHA_FOR_SELLERS_YOUNGER_THAN.ago
  end

  def stream_only?
    alive_product_files.all?(&:stream_only?)
  end

  def listenable?
    has_filegroup?("audio")
  end

  def readable?
    has_filetype?("pdf")
  end

  def can_enable_rentals?
    streamable? && !is_in_preorder_state && !is_recurring_billing
  end

  def can_enable_quantity?
    [NATIVE_TYPE_MEMBERSHIP, NATIVE_TYPE_CALL].exclude?(native_type)
  end

  def eligible_for_installment_plans?
    ProductInstallmentPlan.eligible_for_product?(self)
  end

  def allow_installment_plan?
    installment_plan.present?
  end

  def has_downloadable_content?
    return false unless has_files?

    return false if stream_only?

    true
  end

  def customize_file_per_purchase?
    # Add other forms of per-purchase file customizations here (e.g. video watermark).
    has_stampable_pdfs?
  end

  def allow_parallel_purchases?
    !max_purchase_count? && native_type != NATIVE_TYPE_CALL
  end

  def link
    self
  end

  def long_url(recommended_by: nil, recommender_model_name: nil, include_protocol: true, layout: nil, affiliate_id: nil, query: nil, autocomplete: false)
    host = user.subdomain_with_protocol || UrlService.domain_with_protocol
    options = { host: }
    options[:recommended_by] = recommended_by if recommended_by.present?
    options[:recommender_model_name] = recommender_model_name if recommender_model_name.present?
    options[:layout] = layout if layout.present?
    options[:query] = query if query.present?
    options[:affiliate_id] = affiliate_id if affiliate_id.present?
    options[:autocomplete] = "true" if autocomplete

    product_long_url = Rails.application.routes.url_helpers.short_link_url(general_permalink, options)
    product_long_url.sub!(/\A#{PROTOCOL}:\/\//o, "") unless include_protocol
    product_long_url
  end

  def thumbnail_or_cover_url
    thumbnail_alive&.url || display_asset_previews.find(&:image_url?)&.url
  end

  def for_email_thumbnail_url
    thumbnail_alive&.url ||
      ActionController::Base.helpers.asset_url("native_types/thumbnails/#{native_type}.png")
  end

  def plaintext_description
    return "" if description.blank?

    escaped_description = sanitize(description, tags: [])
    escaped_description = escaped_description.squish
    escaped_description
  end

  def html_safe_description
    return unless description.present?

    Rinku.auto_link(sanitize(description, scrubber: description_scrubber), :all, 'target="_blank" rel="noopener noreferrer nofollow"').html_safe
  end

  def to_param
    unique_permalink
  end

  def twitter_share_url
    twitter_url(long_url, social_share_text)
  end

  def social_share_text
    if user.twitter_handle.present?
      return "I pre-ordered #{name} from @#{user.twitter_handle} on @Gumroad" if is_in_preorder_state

      "I got #{name} from @#{user.twitter_handle} on @Gumroad"
    else
      return "I pre-ordered #{name} on @Gumroad" if is_in_preorder_state

      "I got #{name} on @Gumroad"
    end
  end

  def self.human_attribute_name(attr, _)
    case attr
    when "discover_fee_per_thousand" then "Gumroad fee"
    when "native_type" then "Product type"
    else super
    end
  end

  def as_json(options = {})
    if options[:api_scopes].present?
      as_json_for_api(options)
    elsif options[:mobile].present?
      as_json_for_mobile_api
    elsif options[:variant_details_only].present?
      as_json_variant_details_only
    else
      json = super(only: %i[name description require_shipping preview_url]).merge!(
        "id" => unique_permalink,
        "external_id" => external_id,
        "price" => default_price_cents,
        "currency" => price_currency_type,
        "short_url" => long_url,
        "formatted_price" => price_formatted_verbose,
        "recommendable" => recommendable?,
        "rated_as_adult" => rated_as_adult?,
        "hide_sold_out_variants" => hide_sold_out_variants?,
      )
      json["custom_delivery_url"] = nil # Deprecated
      if preorder_link.present?
        json.merge!(
          "is_preorder" => true,
          "is_in_preorder_state" => is_in_preorder_state,
          "release_at" => preorder_link.release_at.to_s
        )
      end

      json
    end
  end

  def file_info_for_product_page
    removed_file_info_attributes = self.removed_file_info_attributes
    multifile_aware_product_file_info.delete_if { |key, _value| removed_file_info_attributes.include?(key) }
  end

  # Public: Returns the file info (size, dimensions, etc) if there's only one file associated with this product.
  def multifile_aware_product_file_info
    multifile_aware_product_file_info = {}
    if alive_product_files.count == 1
      multifile_aware_product_file_info = alive_product_files.first.file_info(require_shipping)
    end
    multifile_aware_product_file_info
  end

  def single_unit_currency?
    currency.key?("single_unit")
  end

  def remaining_for_sale_count
    return 0 unless variants_available?
    return tiers.first.quantity_left if tiers.size == 1

    minimum_bundle_product_quantity_left = if is_bundle?
      bundle_products.alive.flat_map do
        [_1.product.remaining_for_sale_count, _1.variant&.quantity_left]
      end.compact.min
    end

    product_quantity_left = (max_purchase_count - sales_count_for_inventory) unless max_purchase_count.nil?

    quantity_left = [product_quantity_left, minimum_bundle_product_quantity_left].compact.min
    return if quantity_left.nil?

    [quantity_left, 0].max
  end

  def remaining_call_availabilities
    Product::ComputeCallAvailabilitiesService.new(self).perform
  end

  def options
    if skus_enabled
      skus.not_is_default_sku.alive.map(&:to_option_for_product)
    elsif variant_categories_alive.any?
      variants.where(variant_category: variant_categories_alive.first).in_order.alive.map(&:to_option)
    else
      []
    end
  end

  def variants_or_skus
    skus_enabled? ? skus.not_is_default_sku.alive : alive_variants
  end

  def recurrences
    is_recurring_billing ? {
      default: default_price_recurrence.recurrence,
      enabled: prices.alive.is_buy.sort_by { |price| BasePrice::Recurrence.number_of_months_in_recurrence(price.recurrence) }.map { |price| { recurrence: price.recurrence, price_cents: price.price_cents, id: price.external_id } }
    } : nil
  end

  def rental
    purchase_type != "buy_only" ? { price_cents: rental_price_cents, rent_only: purchase_type == "rent_only" } : nil
  end

  def is_legacy_subscription?
    !is_tiered_membership && is_recurring_billing
  end

  def sales_count_for_inventory
    sales.counts_towards_inventory.sum(:quantity)
  end

  def variants_available?
    return true if variant_categories_alive.empty?

    variant_categories_alive.any?(&:available?)
  end

  # Returns a visible (non-deleted) product identified by a permalink.
  #
  # Params:
  # +general_permalink+ - unique or custom permalink to locate the product by
  # +user+ - if passed, the search will be scoped to this user's products only.
  #          if not passed, the search will return the earliest product by unique or custom permalink.
  #                         NOTE: a custom permalink can match different products by different sellers,
  #                         this option should only be used to support legacy URLs.
  #                         Ref: https://gumroad.slack.com/archives/C01B70APF9P/p1627054984386700
  def self.fetch_leniently(general_permalink, user: nil)
    product_via_legacy_permalink = Link.visible.find_by(id: LegacyPermalink.select(:product_id).where(permalink: general_permalink)) if user.blank?

    product_via_legacy_permalink || Link.by_user(user).visible.by_general_permalink(general_permalink).order(created_at: :asc, id: :asc).first
  end

  def self.fetch(unique_permalink, user: nil)
    Link.by_user(user).visible.find_by(unique_permalink:)
  end

  def can_gift?
    !is_in_preorder_state
  end

  def time_fields
    fields = attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
    fields << "last_partner_sync" if last_partner_sync
    fields
  end

  def general_permalink
    custom_permalink.presence || unique_permalink
  end

  def matches_permalink?(permalink)
    permalink.present? && (permalink.downcase == unique_permalink.downcase || permalink.downcase == custom_permalink&.downcase)
  end

  def permalink_overlaps_with_other_sellers?
    permalinks = [unique_permalink.presence, custom_permalink.presence].compact
    products_by_other_sellers = Link.where.not(user_id:)
    products_by_other_sellers.where(unique_permalink: permalinks).or(products_by_other_sellers.where(custom_permalink: permalinks)).present?
  end

  def add_removed_file_info_attributes(removed_file_info_attributes)
    self.json_data ||= {}
    if self.json_data["removed_file_info_attributes"]
      self.json_data["removed_file_info_attributes"].concat(removed_file_info_attributes)
    else
      self.json_data["removed_file_info_attributes"] = removed_file_info_attributes
    end
  end

  def removed_file_info_attributes
    removed_file_info_attributes = self.json_data.present? ? self.json_data["removed_file_info_attributes"] : []
    if removed_file_info_attributes.present?
      removed_file_info_attributes.map(&:to_sym)
    else
      []
    end
  end

  def save_shipping_destinations!(shipping_destinations)
    shipping_destinations ||= []
    deduped_destinations = shipping_destinations.uniq { |destination| destination["country_code"] }

    if deduped_destinations.size != shipping_destinations.size
      errors.add(:base, "Sorry, shipping destinations have to be unique.")
      raise LinkInvalid, "Sorry, shipping destinations have to be unique."
    end

    remaining_shipping_destinations = self.shipping_destinations.alive.pluck(:id)

    # Cannot empty out shipping destinations for a published physical product
    if alive? && (shipping_destinations.empty? || shipping_destinations.first == "")
      errors.add(:base, "The product needs to be shippable to at least one destination.")
      raise LinkInvalid, "The product needs to be shippable to at least one destination."
    end

    shipping_destinations.each do |destination|
      next if destination.try(:[], "country_code").blank?

      shipping_destination = ShippingDestination.find_or_create_by(country_code: destination["country_code"], link_id: id)
      # TODO: :product_edit_react cleanup
      one_item_rate_cents = destination["one_item_rate_cents"]
      multiple_items_rate_cents = destination["multiple_items_rate_cents"]
      one_item_rate_cents ||= string_to_price_cents(price_currency_type, destination["one_item_rate"])
      multiple_items_rate_cents ||= string_to_price_cents(price_currency_type, destination["multiple_items_rate"])

      begin
        shipping_destination.one_item_rate_cents = one_item_rate_cents
        shipping_destination.multiple_items_rate_cents = multiple_items_rate_cents
        shipping_destination.deleted_at = nil
        shipping_destination.is_virtual_country = ShippingDestination::Destinations::VIRTUAL_COUNTRY_CODES.include?(shipping_destination.country_code)

        self.shipping_destinations << shipping_destination

        # only write to DB if changing attribute
        shipping_destination.save! if shipping_destination.changed?

        remaining_shipping_destinations.delete(shipping_destination.id)
      rescue ActiveRecord::RecordNotUnique => e
        errors.add(:base, "Sorry, shipping destinations have to be unique.")
        raise e
      end
    end

    record_deactivation_timestamp = Time.current
    # Deactivate the remaining shipping destinations that were not echo'ed back
    remaining_shipping_destinations.each do |id|
      ShippingDestination.find(id).update(deleted_at: record_deactivation_timestamp)
    end
  end

  def save_default_sku!(sku_id, custom_sku)
    sku = skus.find_by_external_id(sku_id)
    sku.update!(custom_sku:) unless sku.nil?
  end

  def sku_title
    variant_categories_alive.present? ? variant_categories_alive.map(&:title).join(" - ") : "Version"
  end

  def variant_list(seller = nil)
    return { categories: [], skus: [], skus_enabled: } if variant_categories_alive.empty?

    variants = { categories:
      variant_categories_alive.each_with_index.map do |category, i|
        {
          id: category.external_id,
          i:,
          name: category.title,
          options:
            category.variants.in_order.alive.map do |variant|
              variant.as_json(for_views: true, for_seller: seller.present? && (seller == user || seller.is_team_member?))
            end
        }
      end }

    if skus_enabled
      variants[:skus] = skus.not_is_default_sku.alive.map do |sku|
        sku.as_json(for_views: true)
      end
      variants[:skus_title] = sku_title
      variants[:skus_enabled] = true
    end

    variants
  end

  def as_json_variant_details_only
    variants = { categories: {}, skus: {}, skus_enabled: false }
    return variants if variant_categories_alive.empty? && !skus_enabled?

    variant_categories_alive.each do |category|
      category_hash = {
        title: category.title.present? ? category.title : "Version",
        options: {}
      }
      category.variants.alive.each do |variant|
        category_hash[:options][variant.external_id] = variant.as_json(for_views: true)
      end
      variants[:categories][category.external_id] = category_hash
    end

    if skus_enabled?
      skus.not_is_default_sku.alive.each do |sku|
        variants[:skus][sku.external_id] = sku.as_json(for_views: true)
      end
      variants[:skus_title] = sku_title
      variants[:skus_enabled] = true
    end

    variants
  end

  def reorder_previews(preview_positions)
    asset_previews.alive.each do |preview|
      position = preview_positions[preview.guid].try(:to_i)
      if preview.position != position
        preview.position = position
        preview.save!
      end
    end
  end

  def find_offer_code(code:)
    offer_codes.alive.find_by_code(code) ||
      user.offer_codes.universal_with_matching_currency(price_currency_type).alive.find_by_code(code)
  end

  def find_offer_code_by_external_id(external_id)
    offer_codes.alive.find_by_external_id(external_id) ||
      user.offer_codes.universal_with_matching_currency(price_currency_type).alive.find_by_external_id(external_id)
  end

  # Public: Find all alive offer codes associated with product and user in order of created at.
  #
  # Returns list of offer codes.
  def product_and_universal_offer_codes
    (offer_codes.alive + user.offer_codes.universal_with_matching_currency(price_currency_type).alive).sort_by do |offer_code|
      offer_code["created_at"]
    end
  end

  def purchase_info_for_product_page(requested_user, browser_guid)
    return nil unless requested_user || browser_guid

    eligible_purchases = Purchase.none
    eligible_purchases = requested_user.purchases.where(link: self) if requested_user
    eligible_purchases = sales.where(browser_guid:, purchaser_id: nil) if browser_guid && eligible_purchases.blank?

    eligible_purchases = if is_in_preorder_state
      eligible_purchases.preorder_authorization_successful_or_gift
    else
      eligible_purchases.successful_gift_or_nongift.not_fully_refunded.not_chargedback.not_additional_contribution
    end

    bought_purchase = eligible_purchases.not_is_gift_sender_purchase.last
    bought_purchase&.purchase_info unless bought_purchase&.rental_expired?
  end

  def save_duration!(duration)
    self.duration_in_months = duration.present? ? duration.to_i : nil
    save!
  end

  def confirmed_collaborator
    confirmed_collaborators.alive.take
  end
  alias_method :collaborator, :confirmed_collaborator

  def collaborator_for_display
    confirmed_collaborator.affiliate_user if confirmed_collaborator&.show_as_co_creator_for_product?(self)
  end

  def percentage_revenue_cut_for_user(user)
    is_seller = user.id == user_id

    if !is_collab? || confirmed_collaborator.blank?
      return is_seller ? 100 : 0
    end

    collaborator_percentage_cut = product_affiliates
      .find_by(affiliate: confirmed_collaborator)
      .affiliate_percentage

    if is_seller
      100 - collaborator_percentage_cut
    elsif user.id == confirmed_collaborator.affiliate_user_id
      collaborator_percentage_cut
    else
      0
    end
  end

  def current_base_variants
    BaseVariant.alive.where("link_id = ? OR variant_category_id IN (?)", id, variant_categories_alive.pluck(:id))
  end

  def base_variants
    BaseVariant.where("link_id = ? OR variant_category_id IN (?)", id, variant_categories.pluck(:id))
  end

  def custom_attributes
    self.json_data.present? && self.json_data["custom_attributes"].present? ? self.json_data["custom_attributes"] : []
  end

  def checkout_custom_fields
    user.custom_fields.not_is_post_purchase.global.to_a.concat(custom_fields.not_is_post_purchase)
  end

  def custom_field_descriptors
    checkout_custom_fields.map do |custom_field|
      {
        id: custom_field.external_id,
        type: custom_field.type,
        name: custom_field.name,
        required: custom_field.required,
        collect_per_product: custom_field.collect_per_product,
      }
    end
  end

  %w[custom_summary custom_button_text_option custom_view_content_button_text custom_attributes purchase_terms].each do |method_name|
    define_method "save_#{method_name}" do |argument|
      self.json_data ||= {}
      self.json_data[method_name] = argument
      save
    end
  end

  %w[custom_summary custom_button_text_option custom_view_content_button_text purchase_terms].each do |method_name|
    define_method method_name do
      self.json_data.present? ? self.json_data[method_name] : nil
    end
  end

  def admin_url
    "#{PROTOCOL}://#{DOMAIN}/admin/links/#{unique_permalink}"
  end

  def has_third_party_analytics?(location)
    alive_third_party_analytics.where(location: [location, "all"]).present? || user.third_party_analytics.universal.alive.where(location: [location, "all"]).present?
  end

  def default_price_recurrence
    alive_prices.find(&:is_default_recurrence?)
  end

  def has_adult_keywords?
    [name, description, user.name, user.username, user.bio].any? do |text|
      AdultKeywordDetector.adult?(text)
    end
  end

  # Public: Check if a zip archive should ever be generated for this product
  # This is for a product in general, not a specific purchase of a product.
  #
  # Examples:
  #
  # If a product is rent_only, no files can be downloaded, so don't bother generating
  # a zip file. Return false.
  #
  # If a product is rentable and buyable, there is the possibility for some buyers to
  # download product_files. A zip archive should be prepared. Return true.
  def is_downloadable?
    purchase_type != "rent_only" && !has_stampable_pdfs? && has_downloadable_content?
  end

  def has_content?
    (has_product_level_rich_content? ? alive_rich_contents : alive_variants.flat_map(&:alive_rich_contents)).any? { _1.description.any? }
  end

  def has_offer_codes?
    user.display_offer_code_field && (offer_codes.alive.present? || user.offer_codes.universal_with_matching_currency(price_currency_type).alive.present?)
  end

  def statement_description
    user.name_or_username || "Gumroad"
  end

  def gumroad_amount_for_paypal_order(amount_cents:, affiliate_id: nil, vat_cents: 0, was_recommended: false)
    fee_per_thousand = Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND

    if was_recommended
      gumroad_fee_cents = (amount_cents * (fee_per_thousand + discover_fee_per_thousand - Purchase::GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND)) / 1000
    else
      gumroad_fee_cents = (amount_cents * fee_per_thousand) / 1000
    end

    affiliate_fee_cents = if
      affiliate_id.present? &&
      (affiliate = Affiliate.find_by(id: affiliate_id)) &&
      affiliate&.eligible_for_purchase_credit?(product: link, was_recommended:)

      ((affiliate.affiliate_basis_points / 10_000.0) * amount_cents).floor
    else
      0
    end

    gumroad_fee_cents + affiliate_fee_cents + vat_cents
  end

  def free_trial_details
    return nil unless free_trial_enabled?
    { duration: { amount: free_trial_duration_amount, unit: free_trial_duration_unit } }
  end

  def free_trial_duration
    return nil unless free_trial_enabled?
    free_trial_duration_amount.public_send(free_trial_duration_unit)
  end

  def rated_as_adult?
    is_adult? || user.all_adult_products? || has_adult_keywords?
  end

  def has_customizable_price_option?
    is_tiered_membership? ? tiers.alive.exists?(customizable_price: true) : customizable_price?
  end

  def recurrence_price_enabled?(recurrence)
    prices.alive.is_buy.exists?(recurrence:)
  end

  def ppp_details(ip)
    geo = GeoIp.lookup(ip)
    ppp_factor = purchasing_power_parity_enabled? && geo.present? ? PurchasingPowerParityService.new.get_factor(geo.country_code, user) : 1
    ppp_factor < 1 ?
      {
        country: geo.country_name,
        factor: ppp_factor,
        minimum_price: currency["min_price"]
      } : nil
  end

  def purchasing_power_parity_enabled?
    not_purchasing_power_parity_disabled? && user.purchasing_power_parity_enabled?
  end

  def cart_item(params)
    attrs = {}
    attrs[:rental] = !!params[:rent] && purchase_type != "buy_only"
    attrs[:options] = options
    attrs[:option] = attrs[:options].find { |o| o[:id] == params[:option] } || (native_type != NATIVE_TYPE_COFFEE ? attrs[:options].find { |o| o[:quantity_left] != 0 } : nil)
    variant = attrs[:option] ? Variant.find_by_external_id(attrs[:option][:id]) : nil
    prices = (is_tiered_membership ? variant : self).prices.is_buy.alive
    recurrence = is_recurring_billing ? prices.find { |price| price.recurrence == params[:recurrence] } || prices.find { |price| price.recurrence == default_price_recurrence.recurrence } : nil
    attrs[:recurrence] = recurrence&.recurrence
    attrs[:pay_in_installments] = !!params[:pay_in_installments] && allow_installment_plan?
    attrs[:price] = [
      customizable_price.present? || variant&.customizable_price.present? ? params[:price].to_i : 0,
      (recurrence&.price_cents || (attrs[:rental] ? rental_price_cents : price_cents)) +
      (attrs[:option]&.fetch(:price_difference_cents) || 0)
    ].max
    attrs[:price] = currency["min_price"] if purchasing_power_parity_enabled? && attrs[:price] != 0 && attrs[:price] < currency["min_price"]
    attrs[:quantity] = params[:quantity].to_i if params[:quantity].present?
    attrs[:call_start_time] = native_type == NATIVE_TYPE_CALL ? params[:call_start_time] : nil
    attrs
  end

  def analytics_data
    {
      google_analytics_id: user.google_analytics_id,
      facebook_pixel_id: user.facebook_pixel_id,
      free_sales: !user.skip_free_sale_analytics?,
    }
  end

  def has_multiple_variants?
    skus_enabled? ? skus.alive.not_is_default_sku.count > 1 : alive_variants.count > 1
  end

  def has_active_paid_variants?
    alive_variants.exists?(price_difference_cents: 1..)
  end

  def enable_transcode_videos_on_purchase!
    return if transcode_videos_on_purchase?

    self.transcode_videos_on_purchase = true
    save!
  end

  def auto_transcode_videos?
    user.auto_transcode_videos? || has_successful_sales?
  end

  def find_or_initialize_product_refund_policy
    product_refund_policy || build_product_refund_policy(seller: user)
  end

  def show_in_sections!(section_external_ids)
    user.seller_profile_products_sections.each do |section|
      shown = section.shown_products.include?(id)
      selected = section_external_ids.include?(section.external_id)
      if selected && !shown
        section.update!(shown_products: section.shown_products + [id])
      elsif !selected && shown
        section.update!(shown_products: section.shown_products - [id])
      end
    end
  end

  def has_integration?(integration_type)
    active_integrations.where(type: integration_type).exists?
  end

  def get_integration(integration_type)
    active_integrations.where(type: integration_type).first
  end

  def generate_product_files_archives!(for_files: [])
    if has_product_level_rich_content?
      generate_folder_archives!(for_files:)

      alive_variants.find_each { _1.product_files_archives.alive.each(&:mark_deleted!) }
    else
      alive_variants.find_each do |variant|
        variant.generate_folder_archives!(for_files:)
      end

      product_files_archives.alive.each(&:mark_deleted!)
    end
  end

  def has_product_level_rich_content?
    is_physical? || has_same_rich_content_for_all_variants? || alive_variants.empty?
  end

  def has_embedded_license_key?
    (has_product_level_rich_content? ? alive_rich_contents : alive_variants.flat_map(&:alive_rich_contents)).any?(&:has_license_key?)
  end

  def has_another_collaborator?(collaborator: nil)
    query = pending_or_confirmed_collaborators.alive
    query = query.where.not(id: collaborator.id) if collaborator.present?
    query.exists?
  end

  def is_service?
    SERVICE_TYPES.include?(native_type)
  end

  def cancellation_discount_offer_code
    offer_codes.is_cancellation_discount.alive.first
  end

  def toggle_community_chat!(enable)
    if enable
      return if community_chat_enabled?

      transaction do
        update!(community_chat_enabled: true)
        return if active_community.present?
        community = communities.deleted.order(deleted_at: :asc).last
        if community.present?
          community.mark_undeleted!
        else
          communities.create!(seller: user)
        end
      end
    else
      return unless community_chat_enabled?

      transaction do
        update!(community_chat_enabled: false)
        communities.alive.each(&:mark_deleted!)
      end
    end
  end

  def support_email_or_default
    return user.support_or_form_email unless user.product_level_support_emails_enabled?

    support_email || user.support_or_form_email
  end

  protected
    def downcase_filetype
      self.filetype = filetype.downcase if filetype.present?
    end

    # public: remove_xml_tags
    #
    # Users can add XML tags unknowingly to their product description while copy pasting from another application such as Microsoft Word.
    #
    # We see 2 cases where XML tags appear in product descriptions.
    #
    # First case, we see an XML comment tag:
    #
    # <!--?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?-->
    #
    # Second case, we have an XML tag inserted by copy pasting from Microsoft Word:
    #
    # <!--[if gte mso 9]><xml>\n <w:WordDocument>\n  <w:View>Normal</w:View>\n  <w:Zoom>0</w:Zoom>\n
    # <w:DoNotOptimizeForBrowser></w:DoNotOptimizeForBrowser>\n </w:WordDocument>\n</xml><![endif]-->
    #
    # In both cases we want to remove these added tags. The regex used in this method will remove both of these tags.
    def remove_xml_tags
      return if description.blank?

      self.description = description.gsub(/<!--\?xml.+\?-->|<!--\[if gte mso.+<!\[endif\]-->/m, "")
    end

    def generate_unique_permalink
      chars = ("a".."z").to_a
      candidate = chars.sample
      while self.class.exists?(unique_permalink: candidate) || user.links.where(custom_permalink: candidate).exists? do
        candidate += chars.sample
      end
      candidate
    end

    def set_unique_permalink
      self.unique_permalink ||= generate_unique_permalink
    end

    # Make sure custom permalink does not duplicate a unique permalink of another product by the same user
    def custom_and_unique_permalink_uniqueness
      return if unique_permalink == custom_permalink

      other_products_by_user = id.present? ? user.links.where.not(id:) : user.links
      duplicates_unique_permalink = other_products_by_user.where(unique_permalink: custom_permalink).exists?
      errors.add(:custom_permalink, :taken) if duplicates_unique_permalink
    end

    def custom_permalink_of_licensed_product
      return unless is_licensed?
      return if custom_permalink.blank?

      force_product_id_timestamp = $redis.get(RedisKey.force_product_id_timestamp)&.to_datetime
      return if force_product_id_timestamp.blank?
      return if created_at.blank? || created_at > force_product_id_timestamp

      licensed_products_of_other_sellers = Link.is_licensed
                                               .where(created_at: ..force_product_id_timestamp)
                                               .where.not(user_id:)
      licensed_product_with_duplicate_permalink = licensed_products_of_other_sellers
                                                     .where(unique_permalink: custom_permalink)
                                                     .or(licensed_products_of_other_sellers.where(custom_permalink:))
      return if licensed_product_with_duplicate_permalink.empty?

      errors.add(:custom_permalink, :taken)
    end

    def enforce_user_email_confirmation!
      return if user.confirmed?

      errors.add(:base, "You have to confirm your email address before you can do that.")
      raise LinkInvalid, "You have to confirm your email address before you can do that."
    end

    def enforce_shipping_destinations_presence!
      return unless is_physical
      return if shipping_destinations.alive.present?

      errors.add(:base, "The product needs to be shippable to at least one destination.")
      raise LinkInvalid, "The product needs to be shippable to at least one destination."
    end

    def enforce_merchant_account_exits_for_new_users!
      return if publishable?

      errors.add(:base, "You must connect at least one payment method before you can publish this product for sale.")
      raise LinkInvalid, "You must connect at least one payment method before you can publish this product for sale."
    end

    def free_trial_only_enabled_if_recurring_billing
      if !is_recurring_billing && (free_trial_enabled? || free_trial_duration_unit.present? || free_trial_duration_amount.present?)
        errors.add(:base, "Free trials are only allowed for subscription products.")
      end
    end

    class LinkInvalid < StandardError
    end

    def self.short_url_base
      SHORT_DOMAIN.to_s
    end

  private
    def as_json_for_api(options)
      keep = %w[
        name description require_shipping preview_url
        custom_receipt customizable_price custom_permalink
        subscription_duration
      ]
      cached_default_price_cents = default_price_cents

      ppp_factors = purchasing_power_parity_enabled? ? options[:preloaded_ppp_factors] || PurchasingPowerParityService.new.get_all_countries_factors(user) : nil

      json = super_as_json(only: keep).merge!(
        "id" => external_id,
        "url" => nil, # Deprecated
        "price" => cached_default_price_cents,
        "currency" => price_currency_type,
        "short_url" => long_url,
        "thumbnail_url" => thumbnail&.alive&.url.presence,
        "tags" => tags.pluck(:name),
        "formatted_price" => price_formatted_verbose,
        "published" => alive?,
        "file_info" => multifile_aware_product_file_info,
        "max_purchase_count" => max_purchase_count,
        "deleted" => deleted_at.present?,
        "custom_fields" => custom_field_descriptors.as_json,
        "custom_summary" => custom_summary,
        "is_tiered_membership" => is_tiered_membership?,
        "recurrences" => is_tiered_membership? ? prices.alive.is_buy.map(&:recurrence).uniq : nil,
        "variants" => variant_categories_alive.map do |cat|
          {
            title: cat.title,
            options: cat.alive_variants.map do |variant|
              {
                name: variant.name,
                price_difference: variant.price_difference_cents,
                is_pay_what_you_want: variant.customizable_price?,
                recurrence_prices: is_tiered_membership? ? variant.recurrence_price_values : nil,
                url: nil, # Deprecated
              }
            end.map do
              ppp_factors.blank? ? _1 :
                _1.merge({
                           purchasing_power_parity_prices: _1[:price_difference].present? ? compute_ppp_prices(_1[:price_difference] + cached_default_price_cents, ppp_factors, currency) : nil,
                           recurrence_prices: _1[:recurrence_prices]&.transform_values do |v|
                                                v.merge({ purchasing_power_parity_prices: compute_ppp_prices(v[:price_cents], ppp_factors, currency) })
                                              end,
                         })
            end
          }
        end
      )
      if preorder_link.present?
        json.merge!(
          "is_preorder" => true,
          "is_in_preorder_state" => is_in_preorder_state,
          "release_at" => preorder_link.release_at.to_s
        )
      end

      if ppp_factors.present?
        json["purchasing_power_parity_prices"] = compute_ppp_prices(cached_default_price_cents, ppp_factors, currency)
      end

      if options[:api_scopes].include?("view_sales")
        json["custom_delivery_url"] = nil # Deprecated
        json["sales_count"] = successful_sales_count
        json["sales_usd_cents"] = total_usd_cents
      end

      json
    end

    def compute_ppp_prices(price_cents, factors, currency)
      factors.keys.index_with do |country_code|
        price_cents == 0 ? 0 : [factors[country_code] * price_cents, currency["min_price"]].max.round
      end
    end

    def as_json_for_mobile_api
      super_as_json(only: %w[name description unique_permalink]).merge!(
        created_at:,
        updated_at:,
        content_updated_at: content_updated_at || created_at,
        creator_name: user.name_or_username || "",
        creator_username: user.username || "",
        creator_profile_picture_url: user.avatar_url,
        creator_profile_url: user.profile_url,
        preview_url: preview_oembed_thumbnail_url || preview_url || "",
        thumbnail_url: thumbnail&.alive&.url.presence,
        preview_oembed_url: mobile_oembed_url,
        preview_height: preview_height_for_mobile,
        preview_width: preview_width_for_mobile,
        has_rich_content: true
      )
    end

    def release_custom_permalink_if_possible
      deleted_product = user.links.deleted.find_by(custom_permalink:)
      deleted_product&.update(custom_permalink: nil)
    end

    def create_licenses_for_existing_customers
      CreateLicensesForExistingCustomersWorker.perform_in(5.seconds, id)
    end

    def add_to_profile_sections
      user.seller_profile_products_sections.each do |section|
        next unless section.add_new_products
        section.shown_products = section.shown_products << id
        section.save!
      end
    end

    def alive_category_variants_presence
      return if deleted_at.present?

      has_alive_categories_without_variants = variant_categories.alive.left_joins(:alive_variants).where(base_variants: { id: nil }).exists?

      if has_alive_categories_without_variants
        errors.add(:base, "Sorry, the product versions must have at least one option.")
      end
    end

    def valid_tier_version_structure
      if variant_categories.alive.size != 1
        errors.add(:base, "Memberships should only have one Tier version category.")
        raise LinkInvalid, "Memberships should only have one Tier version category."
        return
      end

      if variant_categories.alive.first.variants.alive.size == 0
        errors.add(:base, "Memberships should have at least one tier.")
        raise LinkInvalid, "Memberships should have at least one tier."
      end
    end

    def quantity_enabled_state_is_allowed
      if quantity_enabled && !can_enable_quantity?
        errors.add(:base, "Customers cannot be allowed to choose a quantity for this product.")
      end
    end

    def custom_permalink_or_is_licensed_changed?
      custom_permalink_changed? || is_licensed_changed?
    end

    def description_scrubber
      unless Loofah::HTML5::SafeList::ACCEPTABLE_CSS_PROPERTIES.include?("position")
        # TODO (vishal): iframe.ly adds "position" style, which is not allowed by default.
        # We should be able to remove this once https://github.com/flavorjones/loofah/pull/258 is merged.
        Loofah::HTML5::SafeList::ACCEPTABLE_CSS_PROPERTIES.add("position")
      end

      Loofah::Scrubber.new do |node|
        if %w[strong b em u s h1 h2 h3 h4 h5 h6 pre code ul ol li hr blockquote p a figure figcaption img div span iframe script br upsell-card public-file-embed review-card].exclude?(node.name) && !node.text?
          node.remove
        elsif node.name == "iframe"
          if node["src"].present? && (URI.parse(node["src"]) rescue nil)&.host == "cdn.iframe.ly"
            node.attributes.each do |attr|
              node.remove_attribute(attr.first) unless %w[src frameborder allowfullscreen scrolling allow style].include?(attr.first)
            end
          else
            node.remove
          end
        elsif node.name == "script" && !(
          node["src"].present? &&
            (URI.parse(node["src"]) rescue nil)&.host == "cdn.iframe.ly" &&
            (URI.parse(node["src"]) rescue nil)&.path == "/embed.js"
        )
          node.remove
        elsif node.name == "upsell-card"
          node.attributes.each do |attr|
            node.remove_attribute(attr.first) unless %w[id productid variantid discount].include?(attr.first)
          end
        elsif node.name == "review-card"
          node.attributes.each do |attr|
            node.remove_attribute(attr.first) unless %w[reviewid].include?(attr.first)
          end
          begin
            review_data = node["reviewid"]
            unless product_reviews.find_by_external_id(review_data)
              node.remove
            end
          end
        else
          Loofah::HTML5::Scrub.scrub_attributes(node)
        end
        # WebViews in native apps don't have a base URL, so the protocol can't be determined automatically for URLs starting with //
        if %w[iframe script img].include?(node.name) && node["src"]&.start_with?("//")
          node.attribute("src").value = "#{PROTOCOL}:#{node["src"]}"
        end
      end
    end

    def reset_moderated_by_iffy_flag
      update_attribute(:moderated_by_iffy, false)
    end

    def queue_iffy_ingest_job_if_unpublished_by_admin
      return unless is_unpublished_by_admin? && !saved_change_to_is_unpublished_by_admin?

      Iffy::Product::IngestJob.perform_async(id)
    end
end
