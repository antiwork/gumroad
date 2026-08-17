# frozen_string_literal: true

class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :confirmable, :omniauthable,
         :recoverable, :rememberable, :trackable, :pwned_password

  # Every save that touches these writes them verbatim into `versions.object_changes`, where GDPR
  # erasure does not reach and rows survive ~10 weeks (gumroad-private#1781). `otp_secret_key` is the
  # plaintext TOTP shared secret and `confirmation_token` is stored raw, so a retained diff
  # reproduces a second factor. `email` is deliberately NOT excluded — `versions_for(:email,
  # :payment_address)` is a live admin consumer (Admin::Users::EmailChangesController).
  has_paper_trail skip: %w[
    encrypted_password
    reset_password_token
    confirmation_token
    otp_secret_key
    twitter_oauth_token
    twitter_oauth_secret
    facebook_access_token
  ]
  has_one_time_password
  include Flipper::Identifier, FlagShihTzu, CurrencyHelper, JsonData, Deletable, MoneyBalance,
          DeviseInternal, PayoutSchedule, SocialTwitter, SocialGoogle, SocialApple, SocialGoogleMobile,
          StripeConnect, Stats, PaymentStats, FeatureStatus, Risk, Compliance, Validations, Taxation, PingNotification,
          AsyncDeviseNotification, Posts, AffiliatedProducts, Followers, LowBalanceFraudCheck, MailerLevel,
          DirectAffiliates, AsJson, Tier, Recommendations, Team, AustralianBacktaxes, WithCdnUrl,
          TwoFactorAuthentication, Versionable, Comments, VipCreator, SignedUrlHelper, Purchases, SecureExternalId,
          AttributeBlockable, PayoutInfo, EmailNormalization, SingleUseResetPasswordToken,
          DashboardNavItems, ReputationSummary
  include Purchase::Searchable::BuyerEmailCallbacks

  has_many :user_external_authentications, dependent: :destroy

  stripped_fields :name, :facebook_meta_tag, :google_analytics_id, :username, :email, :support_email

  # Minimum tags count to show tags section on user profile page
  MIN_TAGS_TO_SHOW_TAGS = 2

  # Max price (in US¢) for an unverified creator
  MAX_PRICE_USD_CENTS_UNLESS_VERIFIED = 500_000

  # Max length for facebook_meta_tag
  MAX_LENGTH_FACEBOOK_META_TAG = 100

  MAX_LENGTH_NAME = 100

  INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX = /:/

  # Soft deletion keeps the row's email set, so a deleted account goes on
  # reserving its address while `by_email` still finds it and login refuses it.
  # Both surfaces must name that state: telling a returning visitor an account
  # "already exists" or to "sign up for a new account" sends them round a loop
  # neither surface can end, because releasing the address is a support write.
  DELETED_ACCOUNT_HOLDS_EMAIL_ERROR = "This email address belonged to a Gumroad account that was deleted, so it can't be used for a new account yet. Email support@gumroad.com and we'll free it up for you."

  DELETED_ACCOUNT_LOGIN_ERROR = "You cannot log in because your account was deleted. Email support@gumroad.com if you'd like to use this email address for a new account."

  MIN_AU_BACKTAX_OWED_CENTS_FOR_CONTACT = 100_00

  MIN_AGE_FOR_SERVICE_PRODUCTS = 30.days

  # Seasoning before a seller can pull funds instantly.
  MIN_ACCOUNT_AGE_FOR_INSTANT_PAYOUTS = 60.days

  MIN_SALES_CENTS_VALUE_FOR_AI_PRODUCT_GENERATION = 10_000

  MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT = 10_000

  # 5% once trailing-30-day GMV is at least $20k. Eligibility is cached so purchase
  # fee calc does not SUM the seller's sales (closed #4283).
  HIGH_VOLUME_FEE_PER_THOUSAND = 50
  HIGH_VOLUME_FEE_THRESHOLD_CENTS = 2_000_000
  HIGH_VOLUME_FEE_WINDOW = 30.days

  # Ceiling on how long a cached avatar URL can keep being served after the file
  # behind it goes away (avatar URLs are otherwise stable for the seller's picture).
  AVATAR_VARIANT_URL_CACHE_TTL = 1.day

  # Only "file exists in storage" is cached (never absence), so a repaired avatar
  # shows up immediately, but a variant that disappears keeps 403ing until this
  # expires. Shared via memcached across the fleet, so it also bounds the storage
  # lookups per variant to about one per window.
  AVATAR_VARIANT_PRESENCE_CACHE_TTL = 5.minutes

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
  has_one :billing_detail, foreign_key: :purchaser_id, dependent: :destroy
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
  has_many :guardians
  has_many :user_compliance_info_requests
  has_many :user_tax_forms
  has_many :scheduled_payouts
  has_many :watched_users
  has_one :active_watched_user, -> { alive }, class_name: "WatchedUser"
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
  has_many :available_cross_sells, -> { cross_sell.alive.available_to_customers }, foreign_key: :seller_id, class_name: "Upsell"
  has_many :blocked_customer_objects, foreign_key: :seller_id
  has_one :seller_profile, foreign_key: :seller_id
  # The root page (slug NULL) is the whole-profile custom HTML takeover;
  # slugged pages are the seller's first-class Pages entries served under the
  # storefront at /<slug>.
  has_one :page, -> { roots }, as: :pageable, dependent: :destroy, autosave: true
  has_many :pages, -> { slugged.order(:created_at) }, as: :pageable, dependent: :destroy
  delegate :custom_html, to: :page, allow_nil: true
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
  has_one :totp_credential, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  has_many :utm_links, dependent: :destroy, foreign_key: :seller_id
  # Persisted store Agent chats (the conversational assistant on the Agent tab).
  has_many :ai_conversations, dependent: :destroy, foreign_key: :seller_id
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
  # Separate from the column above on purpose — see Payment#send_paypal_terminal_failure_email.
  attr_json_data_accessor :payout_date_of_last_paypal_terminal_failure_email
  # The PayPal payout address we took off the account after PayPal permanently refused it, kept so
  # support can put it back and so the payout code can still find the rejection that stands against
  # it. See Payment#invalidate_paypal_payout_address.
  attr_json_data_accessor :invalidated_paypal_payout_address
  attr_json_data_accessor :au_backtax_sales_cents, default: 0
  attr_json_data_accessor :au_backtax_owed_cents, default: 0
  attr_json_data_accessor :gumroad_day_timezone
  attr_json_data_accessor :payout_threshold_cents, default: -> { minimum_payout_threshold_cents }
  attr_json_data_accessor :payout_frequency, default: User::PayoutSchedule::WEEKLY
  attr_json_data_accessor :custom_fee_per_thousand
  attr_json_data_accessor :payouts_paused_by
  attr_json_data_accessor :daily_product_creation_limit
  attr_json_data_accessor :tiktok_pixel_id

  def disable_buyer_local_currency
    ActiveModel::Type::Boolean.new.cast(json_data_for_attr("disable_buyer_local_currency", default: false))
  end
  alias_method :disable_buyer_local_currency?, :disable_buyer_local_currency

  def disable_buyer_local_currency=(value)
    set_json_data_for_attr("disable_buyer_local_currency", ActiveModel::Type::Boolean.new.cast(value))
  end

  # Opt-out of mirroring the seller's USD price ending into the buyer's currency ($9.99 →
  # €8,99 rather than the exact €8,53). It rides along with buyer-local-currency and is on
  # by default for sellers who have that, so a seller who wants the exact converted amount
  # shown and charged sets this. See Checkout::PresentmentRounding.
  def disable_buyer_currency_rounding
    ActiveModel::Type::Boolean.new.cast(json_data_for_attr("disable_buyer_currency_rounding", default: false))
  end
  alias_method :disable_buyer_currency_rounding?, :disable_buyer_currency_rounding

  def disable_buyer_currency_rounding=(value)
    set_json_data_for_attr("disable_buyer_currency_rounding", ActiveModel::Type::Boolean.new.cast(value))
  end

  def high_volume_fee_eligible
    ActiveModel::Type::Boolean.new.cast(json_data_for_attr("high_volume_fee_eligible", default: false))
  end
  alias_method :high_volume_fee_eligible?, :high_volume_fee_eligible

  def high_volume_fee_eligible=(value)
    set_json_data_for_attr("high_volume_fee_eligible", ActiveModel::Type::Boolean.new.cast(value))
    json_data_will_change!
  end

  def high_volume_seller_fee?
    Feature.active?(:high_volume_seller_fee, self) && high_volume_fee_eligible?
  end

  def gumroad_fee_per_thousand
    return custom_fee_per_thousand if custom_fee_per_thousand.present?
    return HIGH_VOLUME_FEE_PER_THOUSAND if high_volume_seller_fee?

    Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND
  end

  def trailing_month_gross_sales_cents
    sales.paid.where("purchases.created_at >= ?", HIGH_VOLUME_FEE_WINDOW.ago).sum(:price_cents)
  end

  def refresh_high_volume_fee_eligibility!
    eligible = trailing_month_gross_sales_cents >= HIGH_VOLUME_FEE_THRESHOLD_CENTS
    return eligible if high_volume_fee_eligible? == eligible

    self.high_volume_fee_eligible = eligible
    save!(validate: false)
    eligible
  end

  attr_blockable :email
  attr_blockable :form_email, object_type: :email
  attr_blockable :email_domain
  attr_blockable :form_email_domain, object_type: :email_domain
  attr_blockable :account_created_ip, object_type: :ip_address

  validates :username, uniqueness: { case_sensitive: true },
                       length: { minimum: 3, maximum: 20 },
                       exclusion: { in: DENYLIST },
                       # Username format ensures -
                       # 1. Username contains only lower case letters and numbers.
                       # 2. Username contains at least one letter.
                       format: { with: /\A[a-z0-9]*[a-z][a-z0-9]*\z/, message: "has to contain at least one letter and may only contain lower case letters and numbers." },
                       allow_nil: true,
                       if: :username_changed? # validate only when seller changes their username

  validates :name, length: { maximum: MAX_LENGTH_NAME, too_long: "Your name is too long. Please try again with a shorter one." },
                   format: { without: INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX, message: "cannot contain colons (:) as it causes email delivery problems. Please remove any colons from your name and try again.", if: :name_changed? }
  validates :facebook_meta_tag, length: { maximum: MAX_LENGTH_FACEBOOK_META_TAG }
  validates :purchasing_power_parity_limit, allow_nil: true, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 100 }

  validates_presence_of :email, if: :email_required?
  validate :email_almost_unique
  validates :email, email_format: true, allow_blank: true, if: :email_changed?
  validates :email, disposable_email: true, on: :create
  validates :kindle_email, format: { with: KINDLE_EMAIL_REGEX }, allow_blank: true, if: :kindle_email_changed?
  validates :support_email, email_format: true, allow_blank: true, if: :support_email_changed?
  validates :support_email, not_reserved_email_domain: true, allow_blank: true, if: :support_email_changed?, unless: :is_team_member?
  validate :google_analytics_id_valid
  validate :tiktok_pixel_id_valid
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
  validate :email_not_from_suspended_gmail_variant, on: :create
  validate :facebook_meta_tag_is_valid
  validates :payment_address, email_format: true, allow_blank: true

  before_validation { self.tiktok_pixel_id = tiktok_pixel_id.strip if tiktok_pixel_id.present? }

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
            29 => :has_dismissed_getting_started_checklist,
            30 => :has_used_cli,
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
            52 => :disable_affiliate_requests,
            53 => :refund_policy_enforced, # Set automatically when a seller's dispute rate is too high; forces a buyer-friendly refund policy. See Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!
            54 => :disable_review_reminders, # Seller setting: when enabled, buyers of this seller's products don't receive review reminder emails.
            55 => :ach_payments_enabled, # Seller opt-in (checkout settings page): offers ACH Direct Debit (us_bank_account) at checkout. Off by default — ACH settles in ~4 business days and content only delivers on settlement, which surprises buyers of time-sensitive digital products (gumroad-private#1143).
            56 => :gifting_disabled, # Seller opt-out (checkout settings page): removes the "Give as a gift" option at checkout for all of this seller's products (gumroad-private#1191).
            57 => :content_moderation_disabled, # Admin-only: exempts every product this seller creates from automated content moderation, including ones that don't exist yet. Link#content_moderation_disabled only covers products that already exist when support grants it (gumroad-private#1742).
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  LINK_PROPERTIES = %w[username twitter_handle bio name google_analytics_id flags
                       facebook_pixel_id tiktok_pixel_id skip_free_sale_analytics disable_third_party_analytics].freeze

  after_update :clear_products_cache, if: -> (user) { (User::LINK_PROPERTIES & user.saved_changes.keys).present? || user.tiktok_pixel_id_changed_in_json_data? || (%w[font background_color highlight_color] & user.seller_profile&.saved_changes&.keys).present? }

  after_save :create_updated_stripe_apple_pay_domain, if: ->(user) { user.saved_change_to_username? }
  after_save :delete_old_stripe_apple_pay_domain, if: ->(user) { user.saved_change_to_username? }
  after_update :update_audience_members_affiliates
  after_update :update_product_search_index!
  after_update :update_alive_cart_email, if: :saved_change_to_email?
  after_commit :move_purchases_to_new_email, on: :update, if: :email_previously_changed?
  after_commit :make_affiliate_of_the_matching_approved_affiliate_requests, on: [:create, :update], if: ->(user) { user.confirmed_at_previously_changed? && user.confirmed? }
  after_commit :generate_subscribe_preview, on: [:create, :update], if: :should_subscribe_preview_be_regenerated?

  state_machine(:user_risk_state, initial: :not_reviewed) do
    before_transition any => %i[flagged_for_fraud flagged_for_tos_violation suspended_for_fraud suspended_for_tos_violation],
                      :do => :not_verified?

    # Clearing a suspension re-enables the seller's products, so callers must pass
    # `clear_suspension: true` to prove a routine review isn't undoing a suspension
    # it never looked at. Applies to all three exits from a suspended state
    # (compliant, on_probation, not_reviewed), not just compliant — see
    # User::Risk#refuse_unauthorized_suspension_clear. The real caller to worry about
    # is LowBalanceFraudCheck#disable_refunds_and_put_on_probation!, which decides off
    # a stale in-memory `suspended?`; this guard re-checks the row at write time.
    before_transition any => %i[compliant on_probation not_reviewed],
                      :do => :refuse_unauthorized_suspension_clear
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :invalidate_active_sessions!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :disable_links_and_tell_chat
    after_transition any => %i[on_probation compliant not_reviewed flagged_for_tos_violation flagged_for_fraud suspended_for_tos_violation suspended_for_fraud],
                     :do => :add_user_comment
    after_transition any => [:flagged_for_tos_violation], :do => :add_product_comment

    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :suspend_sellers_other_accounts
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :block_seller_ip!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :remove_follows_for_suspended_account!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation], :do => :delete_custom_domain!
    after_transition any => %i[suspended_for_fraud suspended_for_tos_violation flagged_for_fraud flagged_for_tos_violation],
                     :do => :add_to_gmail_abuse_filter

    after_transition any => :compliant, :do => :enable_refunds!

    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => %i[compliant on_probation],
                     :do => :enable_links_and_tell_chat
    after_transition %i[suspended_for_fraud suspended_for_tos_violation not_reviewed] => %i[compliant on_probation], :do => :unblock_seller_ip!
    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => :compliant, do: :enable_sellers_other_accounts
    after_transition %i[suspended_for_fraud suspended_for_tos_violation] => %i[compliant on_probation], :do => :create_updated_stripe_apple_pay_domain
    after_transition %i[suspended_for_fraud suspended_for_tos_violation flagged_for_fraud flagged_for_tos_violation] => %i[compliant on_probation],
                     :do => :remove_from_gmail_abuse_filter

    event :mark_compliant do
      transition all => :compliant
    end

    event :mark_not_reviewed do
      transition on_probation: :not_reviewed
    end

    event :flag_for_tos_violation do
      transition %i[not_reviewed compliant flagged_for_fraud] => :flagged_for_tos_violation
    end

    event :flag_for_fraud do
      transition %i[not_reviewed compliant flagged_for_tos_violation] => :flagged_for_fraud
    end

    event :suspend_for_fraud do
      transition %i[not_reviewed compliant on_probation flagged_for_fraud flagged_for_tos_violation] => :suspended_for_fraud
    end

    event :suspend_for_tos_violation do
      transition %i[not_reviewed compliant on_probation flagged_for_tos_violation flagged_for_fraud] => :suspended_for_tos_violation
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
    return ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png") unless avatar.attached?
    cdn_url_for(stored_avatar_variant(resize_to_limit: [size, size]).url)
  rescue ActiveStorage::FileNotFoundError, Errno::ENOENT, ActiveRecord::InvalidForeignKey => e
    Rails.logger.warn("User#resized_avatar_url error (#{id}): #{e.class} => #{e.message}")
    ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png")
  end

  def avatar_url
    return ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png") unless avatar.attached?

    variant_url = cached_avatar_variant_url

    # Falling back to the original upload, which is the size the seller
    # uploaded but is otherwise correct, beats showing no avatar at all.
    return avatar.url if variant_url.blank?

    cdn_url_for(variant_url)
  rescue => e
    Rails.logger.warn("User#avatar_url error (#{id}): #{e.class} => #{e.message}")
    avatar.url
  end

  def avatar_variant(verify_storage: false)
    return unless avatar.attached?

    # 400x400 so avatars stay sharp on Retina/high-DPI screens: the profile
    # settings preview box is 200 CSS px, which is 400 device px at 2x.
    stored_avatar_variant(verify_storage:, resize_to_limit: [400, 400])
  end

  def username
    read_attribute(:username).presence || external_id
  end

  def display_name(prefer_email_over_default_username: false)
    return name if name.present?
    return form_email || username.presence if prefer_email_over_default_username && username == external_id
    username.presence || form_email
  end

  def display_name_or_email
    display_name(prefer_email_over_default_username: true)
  end

  def support_or_form_email
    support_email.presence || form_email
  end

  def has_valid_payout_info?
    PayoutProcessorType.all.any? { PayoutProcessorType.get(_1).has_valid_payout_info?(self) }
  end

  def stripe_and_paypal_merchant_accounts_exist?
    merchant_account(StripeChargeProcessor.charge_processor_id) && paypal_connect_account
  end

  def stripe_or_paypal_merchant_accounts_exist?
    merchant_account(StripeChargeProcessor.charge_processor_id) || paypal_connect_account
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
      merchant_accounts.alive.charge_processor_alive.where(charge_processor_id:).find(&:can_accept_charges?)
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

      next if should_disable && product.purchasing_power_parity_disabled?
      product.purchasing_power_parity_disabled = should_disable
      product.save!(validate: false)
    end
  end

  def product_level_support_emails
    products
      .where.not(support_email: nil)
      .pluck(:support_email, :id)
      .group_by { |support_email, _| support_email }
      .map do |email, pairs|
        {
          email:,
          product_ids: pairs.map { |_, id| Link.to_external_id(id) }
        }
      end
  end

  def update_product_level_support_emails!(entries)
    Product::BulkUpdateSupportEmailService.new(self, entries).perform
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

  # Account-scoped pixel configuration in the shape the frontend's
  # startTrackingForSeller expects. Link#analytics_data delegates here: the
  # pixel ids live on the account, not the product, so profile surfaces (which
  # have no product) can boot the same tracking.
  def analytics_data
    {
      google_analytics_id:,
      facebook_pixel_id:,
      tiktok_pixel_id:,
      free_sales: !skip_free_sale_analytics?,
    }
  end

  def custom_html=(value)
    if value.blank?
      page.custom_html = nil if page.present?
      return
    end

    (page || build_page).custom_html = value
  end

  def has_custom_landing_page?
    custom_html.present?
  end

  # Saved custom HTML only replaces the public profile while the feature is active. Keep this
  # separate from has_custom_landing_page?, which reports saved content for editing and recovery.
  def custom_landing_page_visible?
    Feature.active?(:custom_html_pages, self) && has_custom_landing_page?
  end

  def valid_password?(password)
    super(password)
  rescue BCrypt::Errors::InvalidHash
    logger.info "Account with legacy sha256 password user_id=#{id}"
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

  def is_name_invalid_for_email_delivery?
    name.present? && name.match?(INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX)
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
      # Account-level public media (see Api::V2::MediaController) is purged from storage, not
      # just soft-deleted, so the CDN stops serving it. Rescue per file so one bad blob doesn't
      # roll back the whole account closure.
      PublicFile.alive.where(seller: self, resource: self).find_each do |file|
        file.mark_deleted_and_purge_file!
      rescue => e
        Rails.logger.warn("deactivate!: Failed to purge media file #{file.id} for user #{id}: #{e.message}")
      end
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

  def email_domain
    to_email_domain(email)
  end

  def form_email
    unconfirmed_email.presence || email.presence
  end

  def form_email_domain
    to_email_domain(form_email)
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

  # seller_profiles predates a uniqueness constraint. Lock the seller before a locking/current
  # profile read so first saves serialize without establishing a stale repeatable-read snapshot.
  def with_locked_seller_profile
    with_lock do
      profile_association = association(:seller_profile)
      profile_association.reset
      profile = SellerProfile.lock.find_by(seller_id: id) || build_seller_profile
      profile_association.target = profile
      yield profile
    end
  end

  # Serializes profile-section writes on the seller_profile row. Several paths read-modify-write a
  # section's shown_products/shown_posts (the profile editor, product create/edit, post save), so
  # they take this lock and re-read the sections inside it to avoid clobbering each other. The
  # profile editor holds the same row via #with_locked_seller_profile, so all writers serialize on it.
  # Looked up directly (not via #seller_profile, which builds a record) so callers like product
  # creation don't leave an unsaved seller_profile behind to be autosaved later. A seller without a
  # saved profile has nothing to serialize against, so it just runs the block.
  def with_profile_sections_lock(&block)
    profile = SellerProfile.find_by(seller_id: id)
    profile ? profile.with_lock(&block) : yield
  end

  def time_fields
    attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
  end

  def tiktok_pixel_id_changed_in_json_data?
    return false unless saved_change_to_json_data?

    old_json, new_json = saved_change_to_json_data
    (old_json || {})["tiktok_pixel_id"] != (new_json || {})["tiktok_pixel_id"]
  end

  def clear_products_cache
    array_of_product_ids = links.ids.map { |product_id| [product_id] }
    InvalidateProductCacheWorker.perform_bulk(array_of_product_ids)
  end

  def generate_subscribe_preview
    raise "User must be persisted to generate a subscribe preview" unless persisted?
    GenerateSubscribePreviewJob.perform_async(id)
  end

  def minimum_payout_amount_cents
    # A terminally Stripe-rejected account can't sell anymore, so holding its
    # balance to the normal minimum would strand the money forever — release
    # anything above the $1 transfer floor instead. Appealable rejections
    # (open verification requests remain) keep the normal minimum: the seller
    # may be reinstated, and flushing their balance early at the rejected-
    # account floor would be premature.
    return Payouts::REJECTED_ACCOUNT_MIN_AMOUNT_CENTS if stripe_rejected_payout_floor_applies?

    [payout_threshold_cents, minimum_payout_threshold_cents].max
  end

  # Memoized because the weekly payout batch calls minimum_payout_amount_cents
  # several times per holding-balance user (payability check, schedule, copy),
  # and this check costs two queries (merchant account + open requests). The
  # answer can't change within one payout evaluation of a user instance.
  def stripe_rejected_payout_floor_applies?
    return @_stripe_rejected_payout_floor_applies if defined?(@_stripe_rejected_payout_floor_applies)

    @_stripe_rejected_payout_floor_applies =
      (stripe_account&.stripe_rejected? || false) && !user_compliance_info_requests.requested.exists?
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

  # Reconciles TZ database differences across Rails, Elasticsearch and MySQL: https://github.com/gumroad/web/pull/25208
  # Ignores DST (it's the timezone's Standard offset from UTC, independent of current date).
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

    application = OauthApplication.find_by(uid: OauthApplication::MOBILE_API_OAUTH_APPLICATION_UID)
    if application.present?
      application.revoke_access_tokens_for(self)
    end
  end

  def invalidate_browser_sessions!
    update!(last_active_sessions_invalidated_at: DateTime.current)
  end

  def subdomain
    Subdomain.from_username(username)
  end

  def subdomain_with_protocol
    subdomain_url = subdomain
    return unless subdomain_url

    "#{PROTOCOL}://#{subdomain_url}"
  end

  # Hostnames this seller controls: their Gumroad subdomain and live custom domain.
  # A sandboxed seller-authored-HTML iframe can only navigate the top-level window to
  # one of these — shared Gumroad hosts are deliberately excluded so seller HTML can't
  # walk a visitor around arbitrary gumroad.com paths. Lives on the model so the public
  # product wrapper and the editor's landing-page preview share one source of truth.
  #
  # Custom domain only counts once #active? (DNS verified + valid SSL, same bar
  # UrlService uses) — an unverified domain typed into the field still persists on the
  # record, and trusting mere presence would let seller HTML redirect to an unproven host.
  def custom_html_store_hostnames
    hostnames = []
    hostnames << URI("#{PROTOCOL}://#{subdomain}").host if subdomain.present?
    hostnames << custom_domain.domain if custom_domain&.active?
    hostnames.compact.uniq
  end

  # Exact-host DNS is refreshed by the verification worker, never while rendering a profile.
  def store_host_with_protocol
    custom_domain&.strictly_routable? ? "#{PROTOCOL}://#{custom_domain.domain}" : subdomain_with_protocol
  end

  def auto_transcode_videos?
    tier >= TIER_3
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
      payments.completed.exists? &&
      stripe_accounts_seasoned_for_instant_payouts? &&
      alive_user_compliance_info&.legal_entity_country_code == "US"
  end

  # Anchored on the payout account's age, not signup date — a seller can hold an
  # account for years before connecting one. Every account a payout could land on
  # must season, since destination is picked at payout time; seasoning only the
  # managed account would leave a fresh connected account as a hole. An account
  # inherits seasoning from any earlier account of the same kind (alive or retired),
  # since a country/payout-method change retires one row and creates another —
  # reading only the live row would restart the clock on a longtime seller.
  def stripe_accounts_seasoned_for_instant_payouts?
    managed_account = stripe_account
    return false if managed_account.nil?

    [managed_account, stripe_connect_account].compact.all? do |account|
      seasoned_for_instant_payouts?(account)
    end
  end
  private :stripe_accounts_seasoned_for_instant_payouts?

  def seasoned_for_instant_payouts?(account)
    cutoff = MIN_ACCOUNT_AGE_FOR_INSTANT_PAYOUTS.ago
    return true if account.created_at <= cutoff

    # A predecessor has to have actually carried money: a rejected Stripe::Account.create leaves a
    # row that was mark_deleted! the same second with both charge-processor timestamps still NULL
    # (StripeMerchantAccountManager.cleanup_failed_merchant_account). Counting those would season a
    # minutes-old account off an attempt that never processed anything.
    merchant_accounts.stripe.any? do |predecessor|
      predecessor.created_at <= cutoff &&
        predecessor.is_a_stripe_connect_account? == account.is_a_stripe_connect_account? &&
        !predecessor.stripe_rejected? &&
        (predecessor.charge_processor_deleted? || predecessor.charge_processor_alive?)
    end
  end
  private :seasoned_for_instant_payouts?

  def instant_payouts_supported?
    eligible_for_instant_payouts? && (active_bank_account&.supports_instant_payouts? || false)
  end

  def payouts_paused?
    payouts_paused_internally? || payouts_paused_by_user?
  end

  def payouts_paused_by_source
    return nil unless payouts_paused?

    if payouts_paused_internally?
      [PAYOUT_PAUSE_SOURCE_STRIPE, PAYOUT_PAUSE_SOURCE_SYSTEM].include?(payouts_paused_by) ? payouts_paused_by : PAYOUT_PAUSE_SOURCE_ADMIN
    elsif payouts_paused_by_user?
      PAYOUT_PAUSE_SOURCE_USER
    end
  end

  def payouts_paused_for_reason
    return nil unless payouts_paused?

    case payouts_paused_by_source
    when PAYOUT_PAUSE_SOURCE_ADMIN, PAYOUT_PAUSE_SOURCE_STRIPE
      comments.with_type_payouts_paused.last&.content
    when PAYOUT_PAUSE_SOURCE_SYSTEM
      comments.with_type_on_probation
              .where(author_name: SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS.values)
              .last&.content
    end
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

    # Verified creators are trusted enough to email their audience even before
    # their first payout completes (payouts can sit in transit for weeks when a
    # bank abroad delays crediting the transfer). Admins toggle `verified` from
    # the admin user page. The bypass does not apply while the account is
    # flagged for fraud or a terms-of-service violation — an unresolved risk
    # review must be cleared before verification unlocks early email access.
    (verified? && !flagged?) || has_completed_payouts?
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

  # Read-only when either account-level policies are off (account_level_refund_policy_enabled?
  # false — refunds are then per-product) or the policy has been enforced account-wide for a
  # high dispute rate (Purchase::Blockable#enforce_refund_policy_for_seller_based_on_dispute_rate!),
  # in which case the seller must contact us to change it. The section itself always renders,
  # just disabled with an explanatory note.
  def refund_policy_settings_editable?
    !refund_policy_enforced? && account_level_refund_policy_enabled?
  end

  def has_all_eligible_refund_policies_as_no_refunds?
    return false if product_refund_policies.none?

    product_refund_policies.all?(&:published_and_no_refunds?)
  end

  def tax_form_1099_download_url(year:)
    tax_form_1099_download_url = $redis.get("tax_form_1099_download_url_#{year}_#{external_id}")
    return tax_form_1099_download_url if tax_form_1099_download_url.present?

    begin
      s3_path = tax_form_1099_s3_key(year:)
      s3_filename = s3_path.split("/").last
      download_url = signed_download_url_for_s3_key_and_filename(s3_path, s3_filename, expires_in: 10.years)
      $redis.set("tax_form_1099_download_url_#{year}_#{external_id}", download_url)
      download_url
    rescue
      nil
    end
  end

  def tax_form_1099_s3_bytes(year:)
    Aws::S3::Resource.new.bucket(S3_BUCKET).object(tax_form_1099_s3_key(year:)).get.body.read
  rescue Aws::S3::Errors::NoSuchKey
    nil
  end

  def tax_form_available_years
    (created_at.year..(Time.current.year - 1)).to_a
  end

  private def tax_form_1099_s3_key(year:)
    key = Digest::SHA1.hexdigest("#{year}-#{id}")
    "tax-forms/#{key}/#{external_id}/tax-1099-form-#{year}.pdf"
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
      _1.resource.alive? && _1.resource.community_chat_enabled? ? _1.id : nil
    end.compact.uniq
  end

  def paypal_payout_email
    return payment_address if payment_address.present?

    return nil unless has_paypal_account_connected?

    paypal_connect_account.paypal_account_details&.dig("primary_email")
  end

  # The PayPal address whose rejection history describes this seller's situation, which is not
  # always one we would pay to.
  #
  # Taking a permanently-refused address off the account (Payment#invalidate_paypal_payout_address)
  # removes the only link between the seller and the rejection standing against them, since every
  # part of the payout code finds those rejections by address. Without this, invalidating would
  # silently undo the explanation the seller reads and the block that stopped the retries. So
  # readers asking "what is wrong with this account" use this, while anything deciding where to
  # SEND money keeps using #paypal_payout_email — which is blank, exactly as intended.
  def paypal_payout_email_for_failure_lookup
    paypal_payout_email.presence || invalidated_paypal_payout_address.presence
  end

  def purchased_small_bets?
    small_bets_product_id = GlobalConfig.get("SMALL_BETS_PRODUCT_ID",  2866567)

    purchases.all_success_states_including_test
      .where(link_id: small_bets_product_id)
      .exists?
  end

  def eligible_for_ai_product_generation?
    return true if Rails.env.development?
    return false unless confirmed?
    return false if suspended?
    return false if sales_cents_total < MIN_SALES_CENTS_VALUE_FOR_AI_PRODUCT_GENERATION

    has_completed_payouts?
  end

  # The store Agent can rewrite a seller's live storefront, so it stays behind the same
  # earned-your-way-in bar as AI product generation: real money in, and a payout that
  # proves the account is a going concern rather than a fresh signup experimenting.
  #
  # Never memoize: this backs an authorization check on a long-lived SSE stream, so a
  # suspension mid-conversation has to revoke access on the next check rather than at the
  # next object load.
  #
  # The ordering is what keeps it cheap. sales_cents_total is an Elasticsearch aggregation
  # while has_completed_payouts? is an indexed exists?, so testing the payout first means a
  # seller who has never been paid out short-circuits without touching ES — exactly the
  # pre-launch account this gate exists to stop.
  def eligible_for_store_agent?
    return true if Rails.env.development?
    return false if !confirmed? || suspended? || !has_completed_payouts?

    sales_cents_total >= MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT
  end

  # Devise routes every confirmation *resend* through this method — the public
  # "resend confirmation" form, the Settings resend button, and the library
  # gate all land here. A prior transient delivery failure may have left the
  # target address on SendGrid's bounce/block suppression list, which silently
  # drops every later send including this one, so we clear those suppressions
  # before re-sending (see ResendConfirmationEmailJob for the full rationale).
  #
  # Initial-signup sends go through send_confirmation_instructions instead, so
  # this override adds no suppression lookups to the signup path. We keep
  # Devise's pending_any_confirmation guard so an already-confirmed address
  # still gets the usual "already confirmed" error rather than a pointless send.
  #
  # We stamp confirmation_sent_at here, at enqueue time, because the callers that
  # throttle resends (e.g. the library gate) read it synchronously — if it only
  # updated when the low-priority job actually sends, every request in between
  # would see a stale timestamp and enqueue another duplicate resend.
  #
  # The one-minute floor bounds double-clicks and the public "resend confirmation"
  # form (which has no rack_attack throttle): each enqueue costs SendGrid
  # suppression-API calls in the job, so an unbounded per-user enqueue rate would
  # hand an attacker who knows an unconfirmed address a free API-hammering lever.
  RESEND_CONFIRMATION_ENQUEUE_FLOOR = 1.minute

  def resend_confirmation_instructions
    pending_any_confirmation do
      return if confirmation_sent_at.present? && confirmation_sent_at > RESEND_CONFIRMATION_ENQUEUE_FLOOR.ago
      update_column(:confirmation_sent_at, Time.current)
      ResendConfirmationEmailJob.perform_async(id)
    end
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
    # The cached avatar variant URL, resolving and caching it when there is no
    # usable entry.
    #
    # The version suffix on the cache key lets us abandon previously cached
    # URLs without a backfill: every user's avatar URL is simply recomputed on
    # its next read, and the old entries are left behind for memcached to
    # evict. "_v2" moved us from 128x128 to 400x400 variants. "_v3" abandons
    # the entries written before we checked that the variant file still
    # exists, some of which pointed at files that had disappeared from storage
    # and so returned 403 forever.
    def cached_avatar_variant_url
      cache_key = "attachment_#{avatar.id}_variant_url_v3"
      cached = Rails.cache.read(cache_key)

      # A cached URL is only worth serving while the file behind it is still
      # there, so the variant's storage key is cached next to the URL and
      # checked on every hit. Without that check a variant that disappeared
      # just after its URL was written would 403 for the rest of the day.
      #
      # The check is usually answered by the short-lived presence entry rather
      # than by storage, which is what keeps a page full of avatars cheap. That
      # entry is also the remaining gap: a variant that disappears while it says
      # "present" keeps being served until it expires, so its lifetime
      # (AVATAR_VARIANT_PRESENCE_CACHE_TTL, a few minutes) is deliberately the
      # worst case for a broken avatar.
      if cached.is_a?(Hash) && cached[:url].present? && cached[:key].present? &&
         avatar_variant_file_present?(cached[:key])
        return cached[:url]
      end

      # Ask storage directly rather than trusting the presence entry: this URL
      # is about to be remembered for a day, so it has to be true at the moment
      # we write it.
      variant = avatar_variant(verify_storage: true)
      url = variant&.url.presence
      # Only ever cache a real URL. A blank value here means we could not work
      # out where the variant lives on this pass, and caching that would leave
      # the seller with no profile picture until the entry expired, with no way
      # for them to fix it. The expiry bounds how long any single cached URL
      # can outlive the file it points at.
      if url && variant.key.present?
        Rails.cache.write(cache_key, { url:, key: variant.key }, expires_in: AVATAR_VARIANT_URL_CACHE_TTL)
      end
      url
    end

    # Returns the resized avatar, having confirmed that the resized file is
    # really still in storage.
    #
    # Active Storage decides a variant is "already processed" purely from the
    # presence of an active_storage_variant_records row — it never asks storage
    # whether the resized file is still there. So when a variant's file
    # disappears but its row survives, Active Storage keeps handing out a URL
    # for the missing file: nothing raises, the rescue fallbacks in the avatar
    # methods above never run, and every request for that URL fails with a 403
    # forever. The seller sees no profile picture anywhere and has no way to
    # tell it is our problem rather than their upload having failed, so most of
    # them never report it.
    #
    # When the file is gone we throw the stale row away and resize again from
    # the original upload, which is normally still intact.
    def stored_avatar_variant(verify_storage: false, **transformations)
      variant = avatar.variant(**transformations).processed
      return variant if avatar_variant_file_present?(variant.key, verify_storage:)

      Rails.logger.warn("User#stored_avatar_variant (#{id}): variant file missing from storage, regenerating it")
      variant.destroy
      # The row we just deleted may still be held by the blob's loaded
      # association, which would make the next lookup short-circuit on it
      # again, so drop what is loaded before resizing.
      avatar.blob.variant_records.reset
      avatar.variant(**transformations).processed
    end

    # verify_storage skips the "we saw this file recently" shortcut and asks
    # storage directly. Callers that are about to remember the resulting URL for
    # a long time pass it, so the answer they cache was true at the moment they
    # cached it.
    def avatar_variant_file_present?(key, verify_storage: false)
      # No key at all means Active Storage has nothing to check; let the caller
      # deal with the empty URL that follows rather than resizing in a loop.
      return true if key.blank?

      cache_key = "active_storage_variant_present_#{key}"
      return true if !verify_storage && Rails.cache.read(cache_key)

      unless avatar.blob.service.exist?(key)
        # Drop any stale confirmation so another caller does not trust it.
        Rails.cache.delete(cache_key)
        return false
      end

      Rails.cache.write(cache_key, true, expires_in: AVATAR_VARIANT_PRESENCE_CACHE_TTL)
      true
    rescue => e
      # A lookup that itself failed is not evidence the file is gone.
      # Regenerating avatars for everyone because storage was briefly
      # unreachable would be far worse than serving the URL we already have.
      Rails.logger.warn("User#avatar_variant_file_present? error (#{id}): #{e.class} => #{e.message}")
      true
    end

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

    def update_alive_cart_email
      reload_alive_cart&.update!(email: email)
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

    def to_email_domain(value)
      value.presence && Mail::Address.new(value).domain
    end

    # Checks if a value is purely numeric (returns true for both database IDs and external_ids).
    # Used in redirect logic after external_id lookup fails, to distinguish numeric identifiers
    # from usernames that start with numbers (e.g., "1jyo" should not redirect to user with id=1).
    def self.id?(value)
      value.present? && value.to_s == value.to_i.to_s
    end
end
# warm cache benchmark
