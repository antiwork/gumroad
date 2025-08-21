# frozen_string_literal: true

class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :confirmable, :omniauthable,
         :recoverable, :rememberable, :trackable, :pwned_password

  has_paper_trail
  has_one_time_password
  include Flipper::Identifier, FlagShihTzu, CurrencyHelper, Mongoable, JsonData, Deletable, MoneyBalance,
          DeviseInternal, PayoutSchedule, SocialFacebook, SocialTwitter, SocialGoogle, SocialApple, SocialGoogleMobile,
          StripeConnect, Stats, PaymentStats, FeatureStatus, Risk, Compliance, Validations, Taxation, PingNotification,
          Email, AsyncDeviseNotification, Posts, AffiliatedProducts, Followers, LowBalanceFraudCheck, MailerLevel,
          DirectAffiliates, AsJson, Tier, Recommendations, Team, AustralianBacktaxes, WithCdnUrl,
          TwoFactorAuthentication, Versionable, Comments, VipCreator, SignedUrlHelper, Purchases, SecureExternalId

  stripped_fields :name, :facebook_meta_tag, :google_analytics_id, :username, :email, :support_email

  # Minimum tags count to show tags section on user profile page
  MIN_TAGS_TO_SHOW_TAGS = 2

  # Max price (in US¢) for an unverified creator
  MAX_PRICE_USD_CENTS_UNLESS_VERIFIED = 500_000

  # Max length for facebook_meta_tag
  MAX_LENGTH_FACEBOOK_META_TAG = 100

  MAX_LENGTH_NAME = 100

  MIN_AU_BACKTAX_OWED_CENTS_FOR_CONTACT = 100_00

  MIN_AGE_FOR_SERVICE_PRODUCTS = 30.days

  MIN_SALES_CENTS_VALUE_FOR_AI_PRODUCT_GENERATION = 10_000

  has_many :affiliate_credits, foreign_key: "affiliate_user_id"
  has_many :affiliate_partial_refunds, foreign_key: "affiliate_user_id"
  has_many :affiliate_requests, foreign_key: :seller_id
  has_many :self_service_affiliate_products, foreign_key: :seller_id
  has_many :links
  has_many :products, class_name: "Link"
  has_many :dropbox_files
  has_many :subscriptions
  has_many :oauth_applications,
           class_name: "OauthApplication",
           as: :owner
  has_many :resource_subscriptions
  has_many :devices

  belongs_to :credit_card, optional: true

  # Associate with CustomDomain.alive objects
  has_one :custom_domain, -> { alive }

  has_many :orders, foreign_key: :purchaser_id
  has_many :purchases, foreign_key: :purchaser_id
  has_many :purchased_products, -> { distinct }, through: :purchases, class_name: "Link", source: :link
  has_many :sales, class_name: "Purchase", foreign_key: :seller_id
  has_many :preorders_bought, class_name: "Preorder", foreign_key: :purchaser_id
  has_many :preorders_sold, class_name: "Preorder", foreign_key: :seller_id

  has_many :payments
  has_many :balances
  has_many :balance_transactions
  has_many :credits
  has_many :credits_given, class_name: "Credit", foreign_key: :crediting_user_id
  has_many :bank_accounts
  has_many :installments, foreign_key: :seller_id
  has_many :comments, as: :commentable
  has_many :imported_customers, foreign_key: :importing_user_id
  has_many :invites, foreign_key: :sender_id
  has_many :offer_codes
  has_many :user_compliance_infos
  has_many :user_compliance_info_requests
  has_many :workflows, foreign_key: :seller_id
  has_many :merchant_accounts
  has_many :shipping_destinations
  has_many :tos_agreements
  has_many :product_files, through: :links
  has_many :third_party_analytics
  has_many :zip_tax_rates
  has_many :service_charges
  has_many :recurring_services
  has_many :direct_affiliate_accounts, foreign_key: :affiliate_user_id, class_name: DirectAffiliate.name
  has_many :affiliate_accounts, foreign_key: :affiliate_user_id, class_name: Affiliate.name
  has_many :affiliate_sales, through: :affiliate_accounts, source: :purchases
  has_many :affiliated_products, -> { distinct }, through: :affiliate_accounts, source: :products
  has_many :affiliated_creators, -> { distinct }, through: :affiliated_products, source: :user, class_name: User.name
  has_many :collaborators, foreign_key: :seller_id
  has_many :incoming_collaborators, foreign_key: :affiliate_user_id, class_name: Collaborator.name
  has_many :accepted_alive_collaborations, -> { invitation_accepted.alive }, foreign_key: :affiliate_user_id, class_name: Collaborator.name
  has_many :collaborating_products, through: :accepted_alive_collaborations, source: :products
  has_one :large_seller, dependent: :destroy
  has_one :yearly_stat, dependent: :destroy
  has_many :stripe_apple_pay_domains
  has_one :global_affiliate, -> { alive }, foreign_key: :affiliate_user_id, autosave: true
  has_many :upsells, foreign_key: :seller_id
  has_many :cross_sells, -> { cross_sell.alive }, foreign_key: :seller_id, class_name: "Upsell"
  has_many :blocked_customer_objects, foreign_key: :seller_id
  has_one :seller_profile, foreign_key: :seller_id
  has_many :seller_profile_sections, foreign_key: :seller_id
  has_many :seller_profile_products_sections, foreign_key: :seller_id
  has_many :seller_profile_posts_sections, foreign_key: :seller_id
  has_many :seller_profile_rich_text_sections, foreign_key: :seller_id
  has_many :seller_profile_subscribe_sections, foreign_key: :seller_id
  has_many :seller_profile_featured_product_sections, foreign_key: :seller_id
  has_many :seller_profile_wishlists_sections, foreign_key: :seller_id
  has_many :backtax_agreements
  has_many :custom_fields, foreign_key: :seller_id
  has_many :product_refund_policies, -> { where.not(product: nil) }, foreign_key: :seller_id
  has_many :audience_members, foreign_key: :seller_id
  has_many :alive_bank_accounts, -> { alive }, class_name: "BankAccount"
  has_many :wishlists
  has_many :alive_wishlist_follows, -> { alive }, class_name: "WishlistFollower", foreign_key: :follower_user_id
  has_many :alive_following_wishlists, through: :alive_wishlist_follows, source: :wishlist
  has_many :carts
  has_one :alive_cart, -> { alive }, class_name: "Cart"
  has_many :product_reviews, through: :purchases
  has_one :refund_policy, -> { where(product_id: nil) }, foreign_key: "seller_id", class_name: "SellerRefundPolicy", dependent: :destroy
  has_many :utm_links, dependent: :destroy, foreign_key: :seller_id
  has_many :seller_communities, class_name: "Community", foreign_key: :seller_id, dependent: :destroy
  has_many :community_chat_messages, dependent: :destroy
  has_many :last_read_community_chat_messages, dependent: :destroy
  has_many :community_notification_settings, dependent: :destroy
  has_many :seller_community_chat_recaps, class_name: "CommunityChatRecap", foreign_key: :seller_id, dependent: :destroy

  has_one_attached :avatar
  attr_accessor :avatar_changed
  before_save :set_avatar_changed
  after_commit :reset_avatar_changed

  scope :by_email, ->(email) { where(email:) }
  scope :compliant, -> { where(user_risk_state: "compliant") }
  scope :payment_reminder_risk_state, -> { where("user_risk_state in (?)", PAYMENT_REMINDER_RISK_STATES) }
  scope :not_suspended, -> { without_user_risk_state(:suspended_for_fraud, :suspended_for_tos_violation) }
  scope :created_between, ->(range) { where(created_at: range) if range }
  scope :holding_balance_more_than, lambda { |cents|
    joins(:balances).merge(Balance.unpaid).group("balances.user_id").having("SUM(balances.amount_cents) > ?", cents)
  }
  scope :holding_balance, -> { holding_balance_more_than(0) }
  scope :holding_non_zero_balance, lambda {
    joins(:balances).merge(Balance.unpaid).group("balances.user_id").having("SUM(balances.amount_cents) != 0")
  }

  attribute :recommendation_type, default: User::RecommendationType::OWN_PRODUCTS

  attr_accessor :login, :skip_enabling_two_factor_authentication

  attr_json_data_accessor :background_opacity_percent, default: 100
  attr_json_data_accessor :payout_date_of_last_payment_failure_email
  attr_json_data_accessor :last_ping_failure_notification_at
  attr_json_data_accessor :au_backtax_sales_cents, default: 0
  attr_json_data_accessor :au_backtax_owed_cents, default: 0
  attr_json_data_accessor :gumroad_day_timezone
  attr_json_data_accessor :payout_threshold_cents, default: -> { minimum_payout_threshold_cents }
  attr_json_data_accessor :payout_frequency, default: User::PayoutSchedule::WEEKLY
  attr_json_data_accessor :custom_fee_per_thousand

  validates :username, uniqueness: { case_sensitive: true },
                       length: { minimum: 3, maximum: 20 },
                       exclusion: { in: DENYLIST },
                       # Username format ensures -
                       # 1. Username contains only lower case letters and numbers.
                       # 2. Username contains at least one letter.
                       format: { with: /\A[a-z0-9]*[a-z][a-z0-9]*\z/, message: "has to contain at least one letter and may only contain lower case letters and numbers." },
                       allow_nil: true,
                       if: :username_changed? # validate only when seller changes their username

  validates :name, length: { maximum: MAX_LENGTH_NAME, too_long: "Your name is too long. Please try again with a shorter one." }
  validates :facebook_meta_tag, length: { maximum: MAX_LENGTH_FACEBOOK_META_TAG }
  validates :purchasing_power_parity_limit, allow_nil: true, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }

  validates_presence_of :email, if: :email_required?
  validate :email_almost_unique
  validates_format_of :email, with: EMAIL_REGEX, allow_blank: true, if: :email_changed?
  validates_format_of :kindle_email, with: KINDLE_EMAIL_REGEX, allow_blank: true, if: :kindle_email_changed?
  validates_format_of :support_email, with: EMAIL_REGEX, allow_blank: true, if: :support_email_changed?
  validate :google_analytics_id_valid
  validate :avatar_is_valid
  validate :payout_frequency_is_valid

  validates_presence_of :password, if: :password_required?
  validates_confirmation_of :password, if: :password_required?
  validates_length_of :password, within: 4...128, allow_blank: true

  validates :timezone, inclusion: { in: ActiveSupport::TimeZone::MAPPING.keys << nil, message: "%{value} is not a known time zone." }
  validates :recommendation_type, inclusion: { in: User::RecommendationType::TYPES }

  validates :currency_type, inclusion: { in: CURRENCY_CHOICES.keys, message: "%{value} is not a supported currency." }
  validates :custom_fee_per_thousand, allow_nil: true, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }

  validate :json_data, :json_data_must_be_hash
  validate :account_created_email_domain_is_not_blocked, on: :create
  validate :account_created_ip_is_not_blocked, on: :create
  validate :facebook_meta_tag_is_valid
  validate :support_email_domain_is_not_reserved

  validates_format_of :payment_address, with: EMAIL_REGEX, allow_blank: true

  before_save :append_http
  before_save :save_external_id
  before_create :init_default_notification_settings
  before_create :enable_two_factor_authentication
  before_create :enable_tipping
  before_create :enable_discover_boost
  before_create :set_refund_fee_notice_shown
  before_create :set_refund_policy_enabled
  after_create :create_global_affiliate!
  after_create :create_refund_policy!
  after_create_commit :enqueue_generate_username_job

  has_flags 1 => :announcement_notification_enabled,
            2 => :skip_free_sale_analytics,
            3 => :purchasing_power_parity_enabled,
            4 => :opt_out_simplified_pricing,
            5 => :display_offer_code_field,
            6 => :disable_reviews_after_year,
            7 => :refund_fee_notice_shown,
            8 => :refunds_disabled,
            9 => :two_factor_authentication_enabled,
            10 => :buyer_signup,
            11 => :enforce_session_timestamping,
            12 => :disable_third_party_analytics,
            13 => :enable_verify_domain_third_party_services,
            14 => :purchasing_power_parity_payment_verification_disabled,
            15 => :bears_affiliate_fee,
            16 => :enable_payment_email,
            17 => :has_seen_discover,
            18 => :should_paypal_payout_be_split,
            19 => :pre_signup_affiliate_request_processed,
            20 => :payouts_paused_internally,
            21 => :disable_comments_email,
            22 => :has_dismissed_upgrade_banner,
            23 => :opted_into_upgrading_during_signup,
            24 => :disable_reviews_email,
            25 => :check_merchant_account_is_linked,
            26 => :collect_eu_vat,
            27 => :is_eu_vat_exclusive,
            28 => :is_team_member,
            29 => :has_payout_privilege,
            30 => :has_risk_privilege,
            31 => :disable_paypal_sales,
            32 => :all_adult_products,
            33 => :enable_free_downloads_email,
            34 => :enable_recurring_subscription_charge_email,
            35 => :enable_payment_push_notification,
            36 => :enable_recurring_subscription_charge_push_notification,
            37 => :enable_free_downloads_push_notification,
            38 => :million_dollar_announcement_sent,
            39 => :disable_global_affiliate,
            40 => :require_collab_request_approval,
            41 => :payouts_paused_by_user,
            42 => :opted_out_of_review_reminders,
            43 => :tipping_enabled,
            44 => :show_nsfw_products,
            45 => :discover_boost_enabled,
            46 => :refund_policy_enabled, # DO NOT use directly, use User#account_level_refund_policy_enabled? instead
            47 => :can_connect_stripe,
            48 => :upcoming_refund_policy_change_email_sent,
            49 => :can_create_physical_products,
            50 => :paypal_payout_fee_waived,
            51 => :dismissed_create_products_with_ai_promo_alert,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  LINK_PROPERTIES = %w[username twitter_handle bio name google_analytics_id flags
                       facebook_pixel_id skip_free_sale_analytics disable_third_party_analytics].freeze

  after_update :clear_products_cache, if: -> (user) { (User::LINK_PROPERTIES & user.saved_changes.keys).present? || (%w[font background_color highlight_color] & user.seller_profile&.saved_changes&.keys).present? }

  after_save :create_updated_stripe_apple_pay_domain, if: ->(user) { user.saved_change_to_username? }
  after_save :delete_old_stripe_apple_pay_domain, if: ->(user) { user.saved_change_to_username? }
  after_save :trigger_iffy_ingest
  after_update :update_audience_members_affiliates
  after_update :update_product_search_index!
  after_commit :move_purchases_to_new_email, on: :update, if: :email_previously_changed?
  after_commit :make_affiliate_of_the_matching_approved_affiliate_requests, on: [:create, :update], if: ->(user) { user.confirmed_at_previously_changed? && user.confirmed? }
  after_commit :generate_subscribe_preview, on: [:create, :update], if: :should_subscribe_preview_be_regenerated?
  after_create :insert_null_chargeback_state

  # risk state machine
  #
  #  not_reviewed  → → → → → → → → → → → → → → compliant  ↔  ↔  ↔  ↔ ↕︎
  #  ↓                                         ↓     ↑               ↕︎
  #  ↓ ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ← ←     ↑               ↕︎
  #  ↓                                               ↑               ↕︎
  #  ↓            →  →  →  →  →  →  →  →  →  →  →  → ↑ →  →  →  →  → ↕
  #  ↓           ↑                                   ↑               ↕︎
  #  ↓→  flagged_for_fraud  → suspended_for_fraud  ↔ ↑ ↔  ↔  ↔  ↔ on_probation
  #  ↓      ↓↑                                       ↑               ↕︎
  #  ↓→   flagged_for_tos   →  suspended_for_tos   ↔ ↑ ↔ ↔ ↔ ↔ ↔ ↔ ↔ ↔
  #  ↓          ↓                                    ↓               ↑
  #  ↓ →  →  →  →  →  →  →  →  →  →  →  → →  →  →  → ↑ →  →  →  →  → →
  #
  state_machine(:user_risk_state, initial: :not_reviewed) do
    before_transition any => %i[flagged_for_fraud flagged_for_tos_violation suspended_for_fraud suspended_for_tos_violation],
                      :do => :not_verified?
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :invalidate_active_sessions!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :disable_links_and_tell_chat
    after_transition any => %i[on_probation compliant flagged_for_tos_violation flagged_for_fraud suspended_for_tos_violation suspended_for_fraud],
                     :do => :add_user_comment
    after_transition any => [:flagged_for_tos_violation], :do => :add_product_comment

    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :suspend_sellers_other_accounts
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :block_seller_ip!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :delete_custom_domain!

    after_transition any => :compliant, :do => :enable_refunds!

    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => %i[compliant on_probation],
                     :do => :enable_links_and_tell_chat
    after_transition %i[suspended_for_fraud suspended_for_tos_violation not_reviewed] => %i[compliant on_probation], :do => :unblock_seller_ip!
    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => :compliant, do: :enable_sellers_other_accounts
    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => %i[compliant on_probation], :do => :create_updated_stripe_apple_pay_domain

    event :mark_compliant do
      transition all => :compliant
    end

    event :flag_for_tos_violation do
      transition %i[not_reviewed compliant flagged_for_fraud] => :flagged_for_tos_violation
    end

    event :flag_for_fraud do
      transition %i[not_reviewed compliant flagged_for_tos_violation] => :flagged_for_fraud
    end

    event :suspend_for_fraud do
      transition %i[on_probation flagged_for_fraud] => :suspended_for_fraud
    end

    event :suspend_for_tos_violation do
      transition %i[on_probation flagged_for_tos_violation] => :suspended_for_tos_violation
    end

    event :put_on_probation do
      transition all => :on_probation
    end
  end

  state_machine(:tier_state, initial: :tier_0) do
    state :tier_0, value: TIER_0
    state :tier_1, value: TIER_1
    state :tier_2, value: TIER_2
    state :tier_3, value: TIER_3
    state :tier_4, value: TIER_4

    before_transition any => any, do: -> (user, transition) do
      new_tier = transition.args.first
      return unless new_tier
      raise ArgumentError, "first transition argument must be a valid tier" unless User::TIER_RANGES.has_value?(new_tier)
      raise ArgumentError, "invalid transition argument: new tier can't be the same as old tier" if new_tier == transition.from
      raise ArgumentError, "invalid transition argument: upgrading to lower tier is not allowed" if new_tier < transition.from
    end

    after_transition any => any, do: ->(user, transition) do
      new_tier = transition.args.first || transition.to
      user.update!(tier_state: new_tier)
      user.log_tier_transition(from_tier: transition.from, to_tier: new_tier)
    end

    event :upgrade_tier do
      transition tier_0: %i[tier_1 tier_2 tier_3 tier_4]
      transition tier_1: %i[tier_2 tier_3 tier_4]
      transition tier_2: %i[tier_3 tier_4]
      transition tier_3: %i[tier_4]
    end
  end

  has_one_attached :subscribe_preview
  has_many_attached :annual_reports

  def financial_annual_report_url_for(year: Time.current.year)
    return unless annual_reports.attached?

    blob_url = annual_reports.joins("LEFT JOIN active_storage_blobs ON active_storage_blobs.id = active_storage_attachments.blob_id")
                             .find_by("JSON_CONTAINS(active_storage_blobs.metadata, :year, '$.year')", year:)&.blob&.url

    cdn_url_for(blob_url) if blob_url
  end

  def subscribe_preview_url
    cdn_url_for(subscribe_preview.url) if subscribe_preview.attached?
  rescue => e
    Rails.logger.warn("User#subscribe_preview_url error (#{id}): #{e.class} => #{e.message}")
  end

  def resized_avatar_url(size:)
    return ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png") unless avatar.attached?
    cdn_url_for(avatar.variant(resize_to_limit: [size, size]).processed.url)
  end

  def avatar_url
    return ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png") unless avatar.attached?

    cached_variant_url = Rails.cache.fetch("attachment_#{avatar.id}_variant_url") { avatar_variant.url }
    cdn_url_for(cached_variant_url)
  rescue => e
    Rails.logger.warn("User#avatar_url error (#{id}): #{e.class} => #{e.message}")
    avatar.url
  end

  def avatar_variant
    return unless avatar.attached?

    avatar.variant(resize_to_limit: [128, 128]).processed
  end

  def username
    read_attribute(:username).presence || external_id
  end

  def display_name(prefer_email_over_default_username: false)
    return name if name.present?
    return form_email || username.presence if prefer_email_over_default_username && username == external_id
    username.presence || form_email
  end

  def support_or_form_email
    support_email.presence || form_email
  end

  def has_valid_payout_info?
    PayoutProcessorType.all.any? { PayoutProcessorType.get(_1).has_valid_payout_info?(self) }
  end

  def stripe_and_paypal_merchant_accounts_exist?
    merchant_account(StripeChargeProcessor.charge_processor_id) && merchant_account(PaypalChargeProcessor.charge_processor_id)
  end

  def stripe_or_paypal_merchant_accounts_exist?
    merchant_account(StripeChargeProcessor.charge_processor_id) || merchant_account(PaypalChargeProcessor.charge_processor_id)
  end

  def stripe_connect_account
    merchant_accounts.alive.charge_processor_alive.stripe.find { |ma| ma.is_a_stripe_connect_account? }
  end

  def paypal_connect_account
    merchant_account(PaypalChargeProcessor.charge_processor_id)
  end

  def stripe_account
    merchant_accounts.alive.charge_processor_alive.stripe.find { |ma| !ma.is_a_stripe_connect_account? }
  end

  def merchant_account(charge_processor_id)
    if charge_processor_id == StripeChargeProcessor.charge_processor_id
      if has_stripe_account_connected?
        stripe_connect_account
      else
        merchant_accounts.alive.charge_processor_alive.stripe
            .find { |ma| ma.can_accept_charges? && !ma.is_a_stripe_connect_account? }
      end
    else
      merchant_accounts.alive.charge_processor_alive
          .where(charge_processor_id:)
          .find { |ma| ma.can_accept_charges? }
    end
  end

  def merchant_account_currency(charge_processor_id)
    merchant_account = merchant_account(charge_processor_id)
    currency = merchant_account.try(:currency) || ChargeProcessor::DEFAULT_CURRENCY_CODE
    currency.upcase
  end

  # Public: Get the maximum product price for a user.
  # This is the maximum price that a user can receive in payment for a product.
  # The function returns nil if there is no maximum.
  # Returns:
  #  • nil for verified users
  #  • User::MAX_PRICE_USD_CENTS_UNLESS_VERIFIED for all other users
  def max_product_price
    return nil if verified

    MAX_PRICE_USD_CENTS_UNLESS_VERIFIED
  end

  def min_ppp_factor
    return 0 unless purchasing_power_parity_limit?
    1 - purchasing_power_parity_limit / 100.0
  end

  def purchasing_power_parity_excluded_product_external_ids
    products.purchasing_power_parity_disabled.map(&:external_id)
  end

  def update_purchasing_power_parity_excluded_products!(external_ids)
    products.purchasing_power_parity_disabled.or(products.by_external_ids(external_ids)).each do |product|
      should_disable = external_ids.include?(product.external_id)

      product.update!(purchasing_power_parity_disabled: should_disable) unless should_disable && product.purchasing_power_parity_disabled?
    end
  end

  def save_external_id
    return if external_id.present?

    found = false
    until found
      random = rand(9_999_999_999_999)
      if User.find_by_external_id(random.to_s).nil?
        self.external_id = random.to_s
        found = true
      end
    end
  end

  def self.serialize_from_session(key, _salt)
    # logged in user calls this to get users from sessions. redefined
    # so as to use the cache
    single_key = key.is_a?(Array) ? key.first : key
    find_by(id: single_key)
  end

  def admin_page_url
    Rails.application.routes.url_helpers.admin_user_url(self, protocol: PROTOCOL, host: DOMAIN)
  end

  def profile_url(custom_domain_url: nil, recommended_by: nil)
    uri = URI(custom_domain_url || subdomain_with_protocol)
    uri.query = { recommended_by: }.to_query if recommended_by.present?
    uri.to_s
  end

  alias_method :business_profile_url, :profile_url

  def credit_card_info(creator)
    return CreditCard.test_card_info if self == creator
    return credit_card.as_json if credit_card

    CreditCard.new_card_info
  end

  def user_info(creator)
    {
      email: form_email,
      full_name: name,
      profile_picture_url: avatar_url,
      shipping_information: {
        street_address:,
        zip_code:,
        state:,
        country:,
        city:
      },
      card: credit_card_info(creator),
      admin: is_team_member?
    }
  end

  def name_or_username
    name.presence || username
  end

  def valid_password?(password)
    super(password)
  rescue BCrypt::Errors::InvalidHash
    logger.info "Account with sha256 password: #{inspect}"
    false
  end

  def is_buyer?
    !links.exists? && purchases.successful.exists?
  end

  def is_affiliate?
    DirectAffiliate.exists?(affiliate_user_id: id)
  end

  def account_active?
    alive? && !suspended?
  end

  def deactivate!
    validate_account_closure_balances!

    ActiveRecord::Base.transaction do
      update!(
        deleted_at: Time.current,
        username: nil,
        credit_card_id: nil,
        payouts_paused_internally: true,
      )

      links.each(&:delete!)
      installments.alive.each(&:mark_deleted!)
      user_compliance_infos.alive.each(&:mark_deleted!)
      bank_accounts.alive.each(&:mark_deleted!)
      cancel_active_subscriptions!
      invalidate_active_sessions!

      if custom_domain&.persisted? && !custom_domain.deleted?
        custom_domain.mark_deleted!
      end

      true
    rescue
      false
    end
  end

  def reactivate!
    self.deleted_at = nil
    save!
  end

  def mark_as_invited(referral_id)
    referral_user = User.find_by_external_id(referral_id)
    return unless referral_user

    invite = Invite.where(sender_id: referral_user.id).where(receiver_email: email).last
    invite = Invite.create(sender_id: referral_user.id, receiver_email: email, receiver_id: id) if invite.nil?
    invite.update!(receiver_id: id)
    invite.mark_signed_up
  end

  def form_email
    return unconfirmed_email if unconfirmed_email.present?
    email if email.present?
  end

  def currency_symbol
    symbol_for(currency_type)
  end

  def self.find_for_database_authentication(warden_conditions)
    conditions = warden_conditions.dup
    login = conditions.delete(:login)
    where(conditions).where([
                              "email = :value OR username = :value",
                              { value: login.strip.downcase }
                            ]).first
  end

  def self.find_by_hostname(hostname)
    Subdomain.find_seller_by_hostname(hostname) || CustomDomain.find_by_host(hostname)&.user
  end

  def seller_profile
    super || build_seller_profile
  end

  def time_fields
    attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
  end

  def clear_products_cache
    array_of_product_ids = links.ids.map { |product_id| [product_id] }
    InvalidateProductCacheWorker.perform_bulk(array_of_product_ids)
  end

  def generate_subscribe_preview
    raise "User must be persisted to generate a subscribe preview" unless persisted?
    GenerateSubscribePreviewJob.perform_async(id)
  end

  def insert_null_chargeback_state
    Mongoer.async_write("user_risk_state", { "user_id" => id.to_s, "chargeback_state" => nil })
  end

  def minimum_payout_amount_cents
    [payout_threshold_cents, minimum_payout_threshold_cents].max
  end

  def minimum_payout_threshold_cents
    country_code = alive_user_compliance_info&.legal_entity_country_code
    country = Country.new(country_code) if country_code.present?

    [Payouts::MIN_AMOUNT_CENTS, country&.min_cross_border_payout_amount_usd_cents].compact.max
  end

  def active_bank_account
    bank_accounts.alive.first
  end

  def active_ach_account
    bank_accounts.alive.where("type = ?", AchAccount.name).first
  end

  def dismissed_audience_callout?
    Event.where(event_name: "audience_callout_dismissal", user_id: id).exists?
  end

  def has_workflows?
    workflows.alive.present?
  end

  # Public: Return the alive product files for the user
  #
  # product_id_to_exclude - Each product file belongs to a product, sometimes we do not want to display
  # product files of a certain product (if the user is on the edit page of that product). By passing this id we will
  # ignore product files for that product.
  def alive_product_files_excluding_product(product_id_to_exclude: nil)
    result_set = product_files.alive.merge(Link.alive)

    if product_id_to_exclude
      excluded_product = links.find_by(id: product_id_to_exclude)
      excluded_product_file_urls = excluded_product.alive_product_files.map(&:url)
      result_set = result_set.where.not(link_id: excluded_product.id)
      result_set = result_set.where.not(url: excluded_product_file_urls) if excluded_product_file_urls.present?
    end

    # Remove duplicate product files by url
    result_set.group(:url).includes(:subtitle_files, link: :user)
  end

  # Returns the user's product files by prioritizing the product files of
  # the given product over the the product files of the user's other products
  # that have the same `url` attribute.
  # This is sometimes needed (for an example, in the dynamic product content
  # editor), where we need a product's product files to be preferred over the
  # product files of other products among the duplicates having the same `url`
  # attribute.
  def alive_product_files_preferred_for_product(product)
    result_set = ProductFile.includes(:subtitle_files, link: :user).group(:url)
    product_file_urls = product.alive_product_files.pluck(:url)
    all_user_product_files = product_files.alive.merge(Link.alive)

    return result_set.merge(all_user_product_files) if product_file_urls.empty?

    product_files_not_belonging_to_product_query =
      all_user_product_files
        .where.not(link: product)
        .where.not(url: product_file_urls)
        .to_sql
    product_files_belonging_to_product_query =
      ProductFile.alive.where(link: product).to_sql
    union_query = %{(
      #{product_files_not_belonging_to_product_query}
      UNION
      #{product_files_belonging_to_product_query}
    )}.squish

    result_set.from("#{union_query} AS #{ProductFile.table_name}")
  end

  def should_be_shown_currencies_always?
    currency_type != Currency::USD || ![nil, Currency::USD].include?(payments.last.try(:currency))
  end

  def requires_credit_card?
    purchases.preorder_authorization_successful.exists? || purchases.non_free.has_active_subscription.exists?
  end

  def remove_credit_card
    return false if requires_credit_card?
    self.credit_card_id = nil
    save
  end

  def timezone_id # TZInfo Identifier (TZ database name)
    ActiveSupport::TimeZone::MAPPING.fetch(timezone)
  end

  # Returns the user's UTC offset, formatted (e.g. "-08:00")
  # Useful to resolve inconsistencies between Rails, Elasticsearch and MySQL which may all have
  # different TZ databases: https://github.com/gumroad/web/pull/25208
  # Note that it doesn't acknowledge DST by nature: it is just the difference between the timezone's
  # Standard time and UTC, so the returned value does not change depending on when the method is called.
  def timezone_formatted_offset
    ActiveSupport::TimeZone.new(timezone_id).formatted_offset
  end

  def supports_card?(card)
    return false if card.blank?
    return false if card[:processor] == PaypalChargeProcessor.charge_processor_id && !native_paypal_payment_enabled?
    return false if card[:processor] == BraintreeChargeProcessor.charge_processor_id && native_paypal_payment_enabled?
    true
  end

  def invalidate_active_sessions!
    update!(last_active_sessions_invalidated_at: DateTime.current)

    # Also, revoke all active tokens assigned to the mobile application
    application = OauthApplication.find_by(uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID)
    if application.present?
      Doorkeeper::AccessToken.revoke_all_for(application.id, self)
    end
  end

  def subdomain
    Subdomain.from_username(username)
  end

  def subdomain_with_protocol
    subdomain_url = subdomain
    return unless subdomain_url

    "#{PROTOCOL}://#{subdomain_url}"
  end

  def auto_transcode_videos?
    tier_pricing_enabled? ? tier >= TIER_3 : sales_cents_total >= TIER_3
  end

  def read_attribute_for_validation(attr)
    return read_attribute(attr) if attr == :username
    super
  end

  def compliance_info_resettable?
    return true if stripe_account.blank?
    return false if balances.where(merchant_account_id: stripe_account.id).exists?
    return false if sales.successful.where(merchant_account_id: stripe_account.id).exists?

    true
  end

  def show_refund_fee_notice?
    !refund_fee_notice_shown?
  end

  def has_unconfirmed_email?
    unconfirmed_email.present? || !confirmed?
  end

  def collaborator_for?(product)
    collaborating_products.where(id: product.id).exists?
  end

  def save_gumroad_day_timezone
    return unless waive_gumroad_fee_on_new_sales?
    return if gumroad_day_timezone.present?

    update!(gumroad_day_timezone: timezone)
  end

  def eligible_for_service_products?
    Time.current - created_at > MIN_AGE_FOR_SERVICE_PRODUCTS
  end

  def gumroad_day_saved_fee_cents
    return 0 if gumroad_day_timezone.blank?

    timezone_offset = ActiveSupport::TimeZone.new(gumroad_day_timezone).formatted_offset
    start_time = DateTime.new(2024, 4, 4, 0, 0, 0, timezone_offset)
    end_time = DateTime.new(2024, 4, 5, 0, 0, 0, timezone_offset)

    sales_volume_on_gumroad_day = sales.non_free
                                      .not_recurring_charge
                                      .where(purchase_state: Purchase::NON_GIFT_SUCCESS_STATES)
                                      .where("purchases.created_at >= ? AND purchases.created_at < ?", start_time, end_time)
                                      .sum(:price_cents)

    (sales_volume_on_gumroad_day * 0.10).round
  end

  def gumroad_day_saved_fee_amount
    saved_fee_cents = gumroad_day_saved_fee_cents

    return unless saved_fee_cents > 0

    MoneyFormatter.format(saved_fee_cents, :usd, no_cents_if_whole: true, symbol: true)
  end

  def eligible_for_instant_payouts?
    compliant? &&
      !payouts_paused? &&
      payments.completed.count >= 4 &&
      alive_user_compliance_info&.legal_entity_country_code == "US"
  end

  def instant_payouts_supported?
    eligible_for_instant_payouts? && (active_bank_account&.supports_instant_payouts? || false)
  end

  def payouts_paused?
    payouts_paused_internally? || payouts_paused_by_user?
  end

  def made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?
    ids = merchant_accounts
      .stripe_connect
      .or(merchant_accounts.paypal)
      .pluck(:id)
    return false if ids.empty?

    sales.successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
         .where(merchant_account_id: ids)
         .exists?
  end

  def eligible_for_abandoned_cart_workflows?
    return true if is_team_member?
    return false if suspended?

    has_completed_payouts?
  end

  def eligible_to_send_emails?
    return true if is_team_member?
    return false if suspended?
    return false if sales_cents_total < Installment::MINIMUM_SALES_CENTS_VALUE

    has_completed_payouts?
  end

  LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY = Time.new(2025, 3, 31).end_of_day

  def account_level_refund_policy_delayed?
    Feature.active?(:account_level_refund_policy_delayed_for_sellers, self) && Time.current <= LAST_ALLOWED_TIME_FOR_PRODUCT_LEVEL_REFUND_POLICY
  end

  def account_level_refund_policy_enabled?
    return false if Feature.active?(:seller_refund_policy_disabled_for_all)
    # Allow select accounts to have the account policy-level refund policy disabled until the end of March 2025
    return false if account_level_refund_policy_delayed?

    refund_policy_enabled?
  end

  def has_all_eligible_refund_policies_as_no_refunds?
    return false if product_refund_policies.none?

    product_refund_policies.all?(&:published_and_no_refunds?)
  end

  def tax_form_1099_download_url(year:)
    tax_form_1099_download_url = $redis.get("tax_form_1099_download_url_#{year}_#{external_id}")
    return tax_form_1099_download_url if tax_form_1099_download_url.present?

    begin
      key = Digest::SHA1.hexdigest("#{year}-#{id}")
      s3_path = "tax-forms/#{key}/#{external_id}/tax-1099-form-#{year}.pdf"
      s3_filename = s3_path.split("/").last
      download_url = signed_download_url_for_s3_key_and_filename(s3_path, s3_filename, expires_in: 10.years)
      $redis.set("tax_form_1099_download_url_#{year}_#{external_id}", download_url)
      download_url
    rescue
      nil
    end
  end

  def accessible_communities_ids
    # Communities owned by the seller
    seller_communities = self.seller_communities.alive.includes(:resource).to_a

    # Communities of the products the user has purchased
    buyer_communities = Community.alive.includes(:resource).joins(
      "INNER JOIN links ON communities.resource_type = 'Link' AND communities.resource_id = links.id"
    ).joins(
      "INNER JOIN purchases ON purchases.link_id = links.id"
    ).where(
      "purchases.purchase_state = 'successful' AND (purchases.purchaser_id = ? OR purchases.email = ?)", id, email
    ).to_a

    (seller_communities + buyer_communities).map do
      _1.resource.alive? && Feature.active?(:communities, _1.seller) && _1.resource.community_chat_enabled? ? _1.id : nil
    end.compact.uniq
  end

  def transfer_stripe_balance_to_gumroad_account!
    return if stripe_account.blank? || unpaid_balances.where(merchant_account_id: stripe_account.id).blank?

    ActiveRecord::Base.transaction do
      balances_to_transfer = unpaid_balances.where(merchant_account_id: stripe_account.id)

      # Add a negative credit to make zero the balance currently held against creator's Stripe account.
      amount_cents_usd = balances_to_transfer.sum(:amount_cents)
      amount_cents_holding_currency = balances_to_transfer.sum(:holding_amount_cents)
      Credit.create_for_balance_change_on_stripe_account!(amount_cents_holding_currency: -amount_cents_holding_currency,
                                                          merchant_account: stripe_account,
                                                          amount_cents_usd: -amount_cents_usd)

      # Add a positive credit for the same amount against Gumroad's Stripe account.
      Credit.create_for_credit!(user: self, amount_cents: amount_cents_usd, crediting_user: User.find(GUMROAD_ADMIN_ID))

      # Actually transfer the money from creator's Stripe account to Gumroad's Stripe account.
      TransferStripeConnectAccountBalanceToGumroadJob.perform_async(stripe_account.id, amount_cents_usd)
    end
  end

  def paypal_payout_email
    return payment_address if payment_address.present?

    return nil unless has_paypal_account_connected?

    paypal_connect_account.paypal_account_details&.dig("primary_email")
  end

  def purchased_small_bets?
    small_bets_product_id = GlobalConfig.get("SMALL_BETS_PRODUCT_ID",  2866567)

    purchases.all_success_states_including_test
      .where(link_id: small_bets_product_id)
      .exists?
  end

  def eligible_for_ai_product_generation?
    return false unless Feature.active?(:ai_product_generation, self)
    return true if Rails.env.development?
    return false unless confirmed?
    return false if suspended?
    return false if sales_cents_total < MIN_SALES_CENTS_VALUE_FOR_AI_PRODUCT_GENERATION

    has_completed_payouts?
  end

  protected
    def after_confirmation
      # The password reset link sent to the old email should be invalidated
      # so that if an attacker takes control of that old email they shouldn't
      # be able to reset the password of the victim's account after a new email
      # is confirmed.
      update!(reset_password_token: nil, reset_password_sent_at: nil)
    end

  private
    def append_http
      self.notification_endpoint = "http://#{notification_endpoint}" if notification_endpoint.present? && !notification_endpoint.include?("http")
    end

    def password_required?
      !persisted? || !password.nil? || !password_confirmation.nil?
    end

    def email_required?
      provider.nil? || provider.blank?
    end

    def move_purchases_to_new_email
      if unconfirmed_email.blank? && purchases.exists?
        UpdatePurchaseEmailToMatchAccountWorker.perform_in(10.seconds, id)
      end
    end

    def products_recommendable_conditions_changed?
      saved_change_to_user_risk_state&.include?("compliant") ||
      saved_change_to_payment_address?
    end

    def products_rated_as_adult_conditions_changed?
      saved_change_to_username? ||
        saved_change_to_name? ||
        saved_change_to_bio? ||
        saved_change_to_all_adult_products?
    end

    def update_product_search_index!
      username_or_name_changed = saved_change_to_username? || saved_change_to_name?
      change_list = {
        "is_recommendable" => products_recommendable_conditions_changed?,
        "rated_as_adult" => products_rated_as_adult_conditions_changed?,
        "creator_name" => username_or_name_changed,
      }.select { |_, v| v }.keys
      return if change_list.empty?

      products.find_each do |product|
        product.enqueue_index_update_for(change_list)
      end
    end

    def make_affiliate_of_the_matching_approved_affiliate_requests
      return if pre_signup_affiliate_request_processed? || email.blank?

      AffiliateRequest.approved
                      .where(email:)
                      .each(&:make_requester_an_affiliate!)

      update!(pre_signup_affiliate_request_processed: true)
    end

    FLAGS_TO_ENABLE_BY_DEFAULT = %w{
      enable_payment_email
      enable_payment_push_notification
      enable_free_downloads_email
      enable_free_downloads_push_notification
    }
    private_constant :FLAGS_TO_ENABLE_BY_DEFAULT

    def init_default_notification_settings
      FLAGS_TO_ENABLE_BY_DEFAULT.each do |notification_flag|
        self.public_send("#{notification_flag}=", true)
      end
    end

    def enable_two_factor_authentication
      unless skip_enabling_two_factor_authentication
        self.two_factor_authentication_enabled = true
      end
    end

    def enable_tipping
      self.tipping_enabled = true
    end

    def enable_discover_boost
      self.discover_boost_enabled = true
    end

    def set_refund_fee_notice_shown
      self.refund_fee_notice_shown = true
    end

    def set_refund_policy_enabled
      self.refund_policy_enabled = Feature.active?(:seller_refund_policy_new_users_enabled)
    end

    def enqueue_generate_username_job
      return if read_attribute(:username).present?

      GenerateUsernameJob.perform_async(id)
    end

    def create_updated_stripe_apple_pay_domain
      return unless subdomain.present?
      CreateStripeApplePayDomainWorker.perform_async(id)
    end

    def delete_old_stripe_apple_pay_domain
      return if saved_change_to_username[0].blank?
      domain = Subdomain.from_username(saved_change_to_username[0])
      DeleteStripeApplePayDomainWorker.perform_async(id, domain)
    end

    def update_audience_members_affiliates
      return unless saved_change_to_email?

      affiliate_of_seller_ids = DirectAffiliate.alive.where(affiliate_user: self).select(:seller_id).distinct.pluck(:seller_id)

      affiliate_of_seller_ids.each do |seller_id|
        member = AudienceMember.find_by(seller_id:, email: email_previously_was, affiliate: true)
        next if member.nil?
        affiliate_details = member.details.delete("affiliates")
        member.valid? ? member.save! : member.destroy!

        new_member = AudienceMember.find_or_initialize_by(seller_id:, email:)
        new_member.details["affiliates"] = affiliate_details
        new_member.save!
      end
    end

    def should_subscribe_preview_be_regenerated?
      previously_new_record? ||
        %w[name username].intersect?(saved_changes.keys) ||
        %w[font background_color highlight_color].intersect?(seller_profile.saved_changes.keys) ||
        avatar_changed
    end

    def cancel_active_subscriptions!
      subscriptions.active.each { |s| s.cancel!(by_seller: false) }
    end

    def trigger_iffy_ingest
      return unless saved_change_to_name? ||
                    saved_change_to_username? ||
                    saved_change_to_bio?

      Iffy::Profile::IngestJob.perform_async(id)
    end

    def has_completed_payouts?
      payments.completed.exists? ||
        made_a_successful_sale_with_a_stripe_connect_or_paypal_connect_account?
    end

    def set_avatar_changed
      self.avatar_changed = attachment_changes["avatar"].present?
    end

    def reset_avatar_changed
      self.avatar_changed = false
    end
end
