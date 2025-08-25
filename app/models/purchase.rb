# frozen_string_literal: true

class Purchase < ApplicationRecord
  has_paper_trail

  include Rails.application.routes.url_helpers
  include ActionView::Helpers::DateHelper, CurrencyHelper, ProductsHelper, Mongoable, PurchaseErrorCode,
          ExternalId, JsonData, TimestampScopes, Accounting, Blockable, CardCountrySource, Targeting,
          Refundable, Reviews, PingNotification, Searchable, Risk,
          CreatorAnalyticsCallbacks, FlagShihTzu, AfterCommitEverywhere, CompletionHandler, Integrations,
          ChargeEventsHandler, AudienceMember, Reportable, Recommended, CustomFields, Charge::Disputable,
          Charge::Chargeable, Charge::Refundable, DisputeWinCredits, Order::Orderable, Receipt, UnusedColumns, SecureExternalId

  extend PreorderHelper
  extend ProductsHelper

  unused_columns :custom_fields

  # If a sku-enabled product has no skus (i.e. the product has no variants), then the sku id of the purchase will be "pid_#{external_product_id}".
  SKU_ID_PREFIX_FOR_PRODUCT_WITH_NO_SKUS = "pid_"

  # Gumroad's fees per transaction
  GUMROAD_FEE_PER_THOUSAND = 85
  GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND = 100

  GUMROAD_NON_PRO_FEE_PERCENTAGE = 60

  GUMROAD_FLAT_FEE_PER_THOUSAND = 100
  GUMROAD_DISCOVER_FEE_PER_THOUSAND = 300
  GUMROAD_FIXED_FEE_CENTS = 50
  PROCESSOR_FEE_PER_THOUSAND = 29
  PROCESSOR_FIXED_FEE_CENTS = 30

  MAX_PRICE_RANGE = (-2_147_483_647..2_147_483_647)

  CHARGED_SUCCESS_STATES = %w[preorder_authorization_successful successful]
  NON_GIFT_SUCCESS_STATES = CHARGED_SUCCESS_STATES.dup.push("not_charged")
  ALL_SUCCESS_STATES = NON_GIFT_SUCCESS_STATES.dup.push("gift_receiver_purchase_successful")
  ALL_SUCCESS_STATES_INCLUDING_TEST = ALL_SUCCESS_STATES.dup.push("test_successful")
  ALL_SUCCESS_STATES_EXCEPT_PREORDER_AUTH = ALL_SUCCESS_STATES.dup - ["preorder_authorization_successful"]
  ALL_SUCCESS_STATES_EXCEPT_PREORDER_AUTH_AND_GIFT = ALL_SUCCESS_STATES_EXCEPT_PREORDER_AUTH.dup - ["gift_receiver_purchase_successful"]
  COUNTS_REVIEWS_STATES = %w[successful gift_receiver_purchase_successful not_charged]

  ACTIVE_SALES_SEARCH_OPTIONS = {
    state: NON_GIFT_SUCCESS_STATES,
    exclude_refunded_except_subscriptions: true,
    exclude_unreversed_chargedback: true,
    exclude_non_original_subscription_purchases: true,
    exclude_deactivated_subscriptions: true,
    exclude_bundle_product_purchases: true,
    exclude_commission_completion_purchases: true,
  }.freeze

  # State "preorder_concluded_successfully" and filter `exclude_non_successful_preorder_authorizations` need to be included
  # to be able to return preorders from the time they were created instead of when they were concluded.
  # https://github.com/gumroad/web/pull/17699
  CHARGED_SALES_SEARCH_OPTIONS = {
    state: CHARGED_SUCCESS_STATES + ["preorder_concluded_successfully"],
    exclude_giftees: true,
    exclude_refunded: true,
    exclude_unreversed_chargedback: true,
    exclude_non_successful_preorder_authorizations: true,
    exclude_bundle_product_purchases: true,
    exclude_commission_completion_purchases: true,
  }.freeze

  attr_json_data_accessor :locale, default: -> { "en" }
  attr_json_data_accessor :card_country_source
  attr_json_data_accessor :chargeback_reason
  attr_json_data_accessor :perceived_price_cents
  attr_json_data_accessor :recommender_model_name
  attr_json_data_accessor :custom_fee_per_thousand

  belongs_to :link, optional: true
  has_one :url_redirect
  has_one :gift_given, class_name: "Gift", foreign_key: :gifter_purchase_id
  has_one :gift_received, class_name: "Gift", foreign_key: :giftee_purchase_id
  has_one :license
  has_one :shipment
  belongs_to :purchaser, class_name: "User", optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :credit_card, optional: true
  belongs_to :subscription, optional: true
  belongs_to :price, optional: true
  has_many :events
  has_many :refunds
  has_many :disputes
  belongs_to :offer_code, optional: true
  belongs_to :preorder, optional: true
  belongs_to :zip_tax_rate, optional: true
  belongs_to :merchant_account, optional: true
  has_many :comments, as: :commentable
  has_many :media_locations
  has_one :processor_payment_intent
  has_one :commission_as_deposit, class_name: "Commission", foreign_key: :deposit_purchase_id
  has_one :commission_as_completion, class_name: "Commission", foreign_key: :completion_purchase_id
  has_one :utm_link_driven_sale
  has_one :utm_link, through: :utm_link_driven_sale

  has_many :balance_transactions
  belongs_to :purchase_success_balance, class_name: "Balance", optional: true
  belongs_to :purchase_chargeback_balance, class_name: "Balance", optional: true
  belongs_to :purchase_refund_balance, class_name: "Balance", optional: true

  has_and_belongs_to_many :variant_attributes, class_name: "BaseVariant"
  has_many :base_variants_purchases, class_name: "BaseVariantsPurchase" # used for preloading variant ids without having to also query their records
  has_one :call, autosave: true

  has_one :affiliate_credit
  has_many :affiliate_partial_refunds
  belongs_to :affiliate, optional: true

  has_one :purchase_sales_tax_info
  has_one :purchase_taxjar_info
  has_one :recommended_purchase_info, dependent: :destroy
  has_one :purchase_wallet_type
  has_one :purchase_offer_code_discount
  has_one :purchasing_power_parity_info, dependent: :destroy
  has_one :upsell_purchase, dependent: :destroy
  has_one :purchase_refund_policy, dependent: :destroy
  has_one :order_purchase, dependent: :destroy
  has_one :order, through: :order_purchase, dependent: :destroy
  has_one :charge_purchase, dependent: :destroy
  has_one :charge, through: :charge_purchase, dependent: :destroy
  has_one :early_fraud_warning, dependent: :destroy
  has_one :tip, dependent: :destroy

  has_many :purchase_integrations
  has_many :live_purchase_integrations, -> { alive }, class_name: "PurchaseIntegration"
  has_many :active_integrations, through: :live_purchase_integrations, source: :integration
  has_many :consumption_events

  has_many :product_purchase_records, class_name: "BundleProductPurchase", foreign_key: :bundle_purchase_id
  has_many :product_purchases, through: :product_purchase_records
  has_one :bundle_purchase_record, class_name: "BundleProductPurchase", foreign_key: :product_purchase_id
  has_one :bundle_purchase, through: :bundle_purchase_record, source: :bundle_purchase
  has_one :call

  # Normal purchase state transitions:
  #
  # in_progress  →  successful
  #     ↓
  #   failed
  #
  #
  # Test purchases:
  #
  # in_progress  →  test_successful
  #
  #              →  test_preorder_successful
  #
  #
  # Preorders:
  #
  # in_progress  →  preorder_authorization_successful  →  preorder_concluded_successfully
  #      ↓                                            ↓
  # preorder_authorization_failed          preorder_concluded_unsuccessfully
  #
  # There are two purchases associated with each preorder: one at the time of the preorder
  # authorization that goes through the above state machine. The second for when the
  # preorder is released and the card is actually charged  once the product is released.
  # The second purchase goes through the normal purchase state machine and transition
  # to successful it moves the preorder purchase to 'preorder_concluded_successfully'.
  #
  # Giftee purchases:
  #
  # in_progress  →  gift_receiver_purchase_successful
  #      ↓
  #   gift_receiver_purchase_failed
  #
  # Gift purchases use a normal purchase and a giftee purchase: the gifter's
  # purchase triggers the creation of the giftee purchase, which always has
  # price=0.
  # The gifter will receive a receipt, but the seller's emails and the webhooks
  # will all use the giftee's email.
  #
  # Subscription purchases:
  #
  # (a) Initial purchase of a product without a free trial: Follows the normal purchase
  # state transitions.
  #
  # (b) Initial purchase of a product with free trials enabled:
  #
  # in_progress  →  not_charged
  #     ↓
  #   failed
  #
  # (c) Upgrading or downgrading a subscription: Generates a new "original" subscription
  # purchase with a "not_charged" state
  #
  # in_progress  →  not_charged
  #     ↓
  #   failed

  state_machine :purchase_state, initial: :in_progress do
    before_transition in_progress: any, do: :zip_code_from_geoip

    after_transition any => %i[successful not_charged gift_receiver_purchase_successful test_successful], :do => :create_artifacts_and_send_receipt!, unless: lambda { |purchase|
      purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged], :do => :schedule_subscription_jobs, if: lambda { |purchase|
      purchase.link.is_recurring_billing && !purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged gift_receiver_purchase_successful], :do => :schedule_rental_expiration_reminder_emails, if: lambda { |purchase|
      purchase.is_rental
    }
    after_transition any => %i[successful not_charged gift_receiver_purchase_successful], :do => :schedule_workflow_jobs, if: lambda { |purchase|
      purchase.seller.has_workflows? && !purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged test_successful], :do => :notify_seller!, unless: lambda { |purchase|
      purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged], do: :notify_affiliate!, if: lambda { |purchase|
      purchase.affiliate.present? && !purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged], do: :create_product_affiliate, if: lambda { |purchase|
      purchase.affiliate.present? && purchase.affiliate.global? && !purchase.not_charged_and_not_free_trial?
    }
    after_transition any => :failed, :do => :ban_fraudulent_buyer_browser_guid!
    after_transition any => :failed, :do => :ban_card_testers!
    after_transition any => :failed, :do => :block_purchases_on_product!, if: lambda { |purchase| purchase.price_cents.nonzero? && !purchase.is_recurring_subscription_charge }
    after_transition any => :failed, :do => :pause_payouts_for_seller_based_on_recent_failures!, if: lambda { |purchase| purchase.price_cents.nonzero? }
    after_transition any => :failed, :do => :ban_buyer_on_fraud_related_error_code!
    after_transition any => :failed, :do => :suspend_buyer_on_fraudulent_card_decline!
    after_transition any => :failed, :do => :send_failure_email
    after_transition any => %i[failed successful not_charged], :do => :check_purchase_heuristics
    after_transition any => %i[failed successful not_charged], :do => :score_product
    after_transition any => %i[preorder_authorization_successful successful not_charged preorder_concluded_unsuccessfully], :do => :queue_product_cache_invalidation
    after_transition any => %i[successful preorder_authorization_successful], :do => :touch_variants_if_limited_quantity, unless: lambda { |purchase|
      purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged preorder_authorization_successful], :do => :update_product_search_index!, unless: lambda { |purchase|
      purchase.not_charged_and_not_free_trial?
    }
    after_transition any => %i[successful not_charged], do: :delete_failed_purchases_count
    after_transition any => %i[successful gift_receiver_purchase_successful not_charged], do: :transcode_product_videos, if: lambda { |purchase|
      purchase.link.transcode_videos_on_purchase? && !purchase.not_charged_and_not_free_trial? }
    after_transition any => %i[successful gift_receiver_purchase_successful preorder_authorization_successful
                               test_successful test_preorder_successful not_charged], :do => :send_notification_webhook, unless: lambda { |purchase|
                                                                                                                                   purchase.not_charged_and_not_free_trial?
                                                                                                                                 }
    after_transition any => :successful, :do => :block_fraudulent_free_purchases!
    after_transition any => any, :do => :log_transition
    after_transition any => [:successful, :not_charged, :gift_receiver_purchase_successful], :do => :trigger_iffy_moderation, if: lambda { |purchase|
      purchase.price_cents > 0 && !purchase.link.moderated_by_iffy
    }

    # normal purchase transitions:

    event :mark_successful do
      transition %i[in_progress] => :successful,
                 if: ->(purchase) { !purchase.is_preorder_authorization && !purchase.is_gift_receiver_purchase }
    end

    event :mark_failed do
      transition in_progress: :failed, if: ->(purchase) { !purchase.is_preorder_authorization }
    end

    # giftee purchase transitions:

    event :mark_gift_receiver_purchase_successful do
      transition in_progress: :gift_receiver_purchase_successful, if: ->(purchase) { purchase.is_gift_receiver_purchase }
    end

    event :mark_gift_receiver_purchase_failed do
      transition in_progress: :gift_receiver_purchase_failed, if: ->(purchase) { purchase.is_gift_receiver_purchase }
    end

    # preorder authorization transitions:

    event :mark_preorder_authorization_successful do
      transition in_progress: :preorder_authorization_successful, if: ->(purchase) { purchase.is_preorder_authorization }
    end

    event :mark_preorder_authorization_failed do
      transition in_progress: :preorder_authorization_failed, if: ->(purchase) { purchase.is_preorder_authorization }
    end

    event :mark_preorder_concluded_successfully do
      transition preorder_authorization_successful: :preorder_concluded_successfully
    end

    event :mark_preorder_concluded_unsuccessfully do
      transition preorder_authorization_successful: :preorder_concluded_unsuccessfully
    end

    event :mark_test_successful do
      transition in_progress: :test_successful
    end

    event :mark_test_preorder_successful do
      transition in_progress: :test_preorder_successful
    end

    state :successful do
      validate { |purchase| purchase.send(:financial_transaction_validation) }
      # Read http://rdoc.info/github/pluginaweek/state_machine/master/StateMachine/Integrations/ActiveRecord
      # section "Validations" for why this validator is called in this way.
    end

    # updating subscription transitions. `not_charged` state is used when upgrading
    # subscriptions. Newly-created "original subscription purchases" are never charged,
    # but are simply used as a template for charges going forward.

    event :mark_not_charged do
      transition any => :not_charged
    end
  end

  before_validation :downcase_email, if: :email_changed?

  validate :must_have_valid_email
  validate :not_double_charged, on: :create
  validate :seller_is_link_user
  validate :free_trial_purchase_set_correctly, on: :create
  validate :gift_purchases_cannot_be_on_installment_plans
  %w[seller price_cents total_transaction_cents fee_cents].each do |f|
    validates f.to_sym, presence: true
  end
  # address exists for products that require shipping and not recurring purchase and preorders that are not physical
  # this ensures preorders that require shipping at a later date will pass this validation
  %w[full_name street_address country state zip_code city].each do |f|
    validates f.to_sym, presence: true, on: :create,
                        if: -> { link.is_physical || (link.require_shipping? && !is_recurring_subscription_charge && !is_preorder_charge?) }
    validates f.to_sym, presence: true, on: :update,
                        if: -> { is_updated_original_subscription_purchase && (link.is_physical || link.require_shipping?) && !is_recurring_subscription_charge && !is_preorder_charge? }
  end
  validates :call, presence: true, if: -> { link.native_type == Link::NATIVE_TYPE_CALL }
  validates_inclusion_of :recommender_model_name, in: RecommendedProductsService::MODELS, allow_nil: true
  validates :purchaser, presence: true, if: -> { is_gift_receiver_purchase && gift&.is_recipient_hidden? }
  validates :custom_fee_per_thousand, allow_nil: true, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1000 }

  # before_create instead of validate since we want to persist the purchases that fail these.
  before_create :product_is_sellable
  before_create :product_is_not_blocked
  before_create :validate_purchase_type
  before_create :variants_available
  before_create :variants_satisfied
  before_create :sold_out
  before_create :validate_offer_code
  before_create :price_not_too_low
  before_create :price_not_too_high
  before_create :perceived_price_cents_matches_price_cents
  before_create :validate_subscription
  before_create :validate_shipping
  before_create :validate_quantity
  before_create :assign_is_multiseat_license
  before_create :check_for_fraud

  before_save :assign_default_rental_expired
  before_save :to_mongo
  before_save :truncate_referrer

  after_commit :attach_credit_card_to_purchaser,
               on: :update,
               if: -> (purchase) { Feature.active?(:attach_credit_card_to_purchaser) && purchase.previous_changes[:purchaser_id].present? && purchase.purchaser &&
                                   purchase.subscription }

  after_commit :enqueue_update_sales_related_products_infos_job, if: -> (purchase) {
    purchase.purchase_state_previously_changed? && purchase.purchase_state == "successful"
  }

  # Entities that store the product price, tax information and transaction price

  # price_cents - Price cents is the cost of the product as seen by the seller, including Gumroad fees.

  # tax_cents - Tax that the seller is responsible for. This amount is remitted to the seller.
  # The tax amount(tax_cents) is either intrinsic or added on to price_cents.
  # This is controlled by the flag was_tax_excluded_from_price and done at the time of processing (see #process!)

  # gumroad_tax_cents - Tax that Gumroad is responsible for. This amount is NOT remitted to the seller.
  # Eg. VAT an EU buyer is charged.

  # shipping_cents - Shipping that is calculated.

  # total_transaction_cents - Total transaction cents is the amount the buyer is charged
  # This amount includes charges that are not within the scope of the seller - like VAT
  # Is equivalent to price_cents + gumroad_tax_cents

  has_flags 1 => :is_additional_contribution,
            2 => :is_refund_chargeback_fee_waived, # Only used for refunds, as chargeback fees are always waived as of now
            3 => :is_original_subscription_purchase,
            4 => :is_preorder_authorization,
            5 => :is_multi_buy,
            6 => :is_gift_receiver_purchase,
            7 => :is_gift_sender_purchase,
            8 => :DEPRECATED_credit_card_zipcode_required,
            9 => :was_product_recommended,
            10 => :chargeback_reversed,
            11 => :was_zipcode_check_performed,
            12 => :is_upgrade_purchase,
            13 => :was_purchase_taxable,
            14 => :was_tax_excluded_from_price,
            15 => :is_rental,
            # Before we introduced the flat 10% fee `was_discover_fee_charged` was set if the discover fee was charged.
            # Now it is set if the improved product placement fee is charged.
            16 => :was_discover_fee_charged,
            17 => :is_archived,
            18 => :is_archived_original_subscription_purchase,
            19 => :is_free_trial_purchase,
            20 => :is_deleted_by_buyer,
            21 => :is_buyer_blocked_by_admin,
            22 => :is_multiseat_license,
            23 => :should_exclude_product_review,
            24 => :is_purchasing_power_parity_discounted,
            25 => :is_access_revoked,
            26 => :is_bundle_purchase,
            27 => :is_bundle_product_purchase,
            28 => :is_part_of_combined_charge,
            29 => :is_commission_deposit_purchase,
            30 => :is_commission_completion_purchase,
            31 => :is_installment_payment,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_accessor :chargeable, :card_data_handling_error, :save_card, :price_range, :friend_actions,
                :discount_code, :url_parameters, :purchaser_plugins, :is_automatic_charge, :sales_tax_country_code_election, :business_vat_id,
                :save_shipping_address, :flow_of_funds, :prorated_discount_price_cents,
                :original_variant_attributes, :original_price, :is_updated_original_subscription_purchase,
                :is_applying_plan_change, :setup_intent, :charge_intent, :setup_future_charges, :skip_preparing_for_charge,
                :installment_plan

  delegate :email, :name, to: :seller, prefix: "seller"
  delegate :name, to: :link, prefix: "link", allow_nil: true
  delegate :display_product_reviews?, to: :link

  scope :by_email, ->(email) { where(email:) }
  scope :with_stripe_fingerprint, -> { where.not(stripe_fingerprint: nil) }
  scope :successful, -> { where(purchase_state: "successful") }
  scope :test_successful, -> { where(purchase_state: "test_successful") }
  scope :in_progress, -> { where(purchase_state: "in_progress") }
  scope :in_progress_or_successful_including_test, -> { where(purchase_state: %w(in_progress successful test_successful)) }
  scope :not_in_progress, -> { where.not(purchase_state: "in_progress") }
  scope :not_successful, -> { without_purchase_state(:successful) }
  scope :successful_gift_or_nongift, -> { where(purchase_state: ["successful", "gift_receiver_purchase_successful"]) }
  scope :failed, -> { where(purchase_state: "failed") }
  scope :preorder_authorization_successful, -> { where(purchase_state: "preorder_authorization_successful") }
  scope :preorder_authorization_successful_or_gift, -> { where(purchase_state: ["preorder_authorization_successful", "gift_receiver_purchase_successful"]) }
  scope :successful_or_preorder_authorization_successful, -> { where(purchase_state: Purchase::CHARGED_SUCCESS_STATES) }
  scope :preorder_authorization_failed, -> { where(purchase_state: "preorder_authorization_failed") }
  scope :not_charged, -> { where(purchase_state: "not_charged") }
  scope :all_success_states, -> { where(purchase_state: Purchase::ALL_SUCCESS_STATES) }
  scope :all_success_states_including_test, -> { where(purchase_state: Purchase::ALL_SUCCESS_STATES_INCLUDING_TEST) }
  scope :all_success_states_except_preorder_auth_and_gift, -> { where(purchase_state: Purchase::ALL_SUCCESS_STATES_EXCEPT_PREORDER_AUTH_AND_GIFT) }
  scope :exclude_not_charged_except_free_trial, -> { where("purchases.purchase_state != 'not_charged' OR purchases.flags & ? != 0", Purchase.flag_mapping["flags"][:is_free_trial_purchase]) }
  scope :stripe_failed, -> { failed.where("purchases.stripe_fingerprint IS NOT NULL AND purchases.stripe_fingerprint != ''") }
  scope :non_free, -> { where("purchases.price_cents != 0") }
  scope :successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback, lambda {
    where(purchase_state: %w[successful preorder_authorization_successful gift_receiver_purchase_successful]).
      not_fully_refunded.
      not_chargedback_or_chargedback_reversed.
      not_is_gift_receiver_purchase
  }
  scope :paid, -> { successful.where("purchases.price_cents > 0").where("stripe_refunded is null OR stripe_refunded = 0") }
  scope :not_fully_refunded, -> { where("purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0") }
  # always include subscription purchase regardless if refunded or not to show up in library and customers tab:
  scope :not_refunded_except_subscriptions, lambda {
    where("(purchases.subscription_id IS NULL AND (purchases.stripe_refunded IS NULL OR purchases.stripe_refunded = 0)) OR " \
          "purchases.subscription_id IS NOT NULL")
  }
  scope :chargedback, -> { successful.where("purchases.chargeback_date IS NOT NULL") }
  scope :not_chargedback, -> { where("purchases.chargeback_date IS NULL") }
  scope :not_chargedback_or_chargedback_reversed, lambda {
    where("purchases.chargeback_date IS NULL OR " \
 "(purchases.chargeback_date IS NOT NULL AND purchases.flags & ? != 0)", Purchase.flag_mapping["flags"][:chargeback_reversed])
  }
  scope :not_additional_contribution, -> { where("purchases.flags IS NULL OR purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:is_additional_contribution]) }
  scope :for_products, ->(products) { where(link_id: products) if products.present? }
  scope :not_subscription_or_original_purchase, -> {
    where("purchases.subscription_id IS NULL OR purchases.flags & ? = ?",
          Purchase.flag_mapping["flags"][:is_original_subscription_purchase], Purchase.flag_mapping["flags"][:is_original_subscription_purchase])
  }
  # TODO: since Memberships, `not_recurring_charge` & `recurring_charge` are not an accurate names for what the scopes filter, and they should be renamed.
  scope :not_recurring_charge, lambda { not_subscription_or_original_purchase }
  scope :recurring_charge, -> { where("purchases.subscription_id IS NOT NULL AND purchases.flags & ? = 0", Purchase.flag_mapping["flags"][:is_original_subscription_purchase]) }
  scope :has_active_subscription, lambda {
    without_purchase_state(:test_successful).joins("INNER JOIN subscriptions ON subscriptions.id = purchases.subscription_id")
      .where("subscriptions.failed_at IS NULL AND subscriptions.ended_at IS NULL AND (subscriptions.cancelled_at IS NULL OR subscriptions.cancelled_at > ?)", Time.current)
  }
  scope :no_or_active_subscription, lambda {
    joins("LEFT OUTER JOIN subscriptions ON subscriptions.id = purchases.subscription_id")
      .where("subscriptions.deactivated_at IS NULL")
  }
  scope :inactive_subscription, lambda {
    joins("LEFT OUTER JOIN subscriptions ON subscriptions.id = purchases.subscription_id")
      .where("subscriptions.deactivated_at IS NOT NULL")
  }
  scope :can_access_content, lambda {
    joins(:link)
      .joins("LEFT OUTER JOIN subscriptions ON subscriptions.id = purchases.subscription_id")
      .where("subscriptions.deactivated_at IS NULL OR links.flags & ? = 0", Link.flag_mapping["flags"][:block_access_after_membership_cancellation])
  }
  scope :counts_towards_inventory, lambda {
    where(purchase_state: ["preorder_authorization_successful", "in_progress", "successful", "not_charged"])
      .left_joins(:subscription)
      .not_subscription_or_original_purchase
      .not_additional_contribution
      .not_is_archived_original_subscription_purchase
      .where(subscription: { deactivated_at: nil })
  }
  scope :counts_towards_offer_code_uses, lambda {
    where(purchase_state: NON_GIFT_SUCCESS_STATES)
      .not_recurring_charge
      .not_is_archived_original_subscription_purchase
  }
  scope :counts_towards_volume, lambda {
    successful
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
  }
  scope :created_after, ->(start_at) { where("purchases.created_at > ?", start_at) if start_at.present? }
  scope :created_before, ->(end_at) { where("purchases.created_at < ?", end_at) if end_at.present? }
  scope :paypal_orders, -> { where.not(paypal_order_id: nil) }
  scope :unsuccessful_paypal_orders, lambda { |created_after_timestamp, created_before_timestamp|
    not_successful.paypal_orders
                  .created_after(created_after_timestamp)
                  .created_before(created_before_timestamp)
  }

  scope :with_credit_card_id, -> { where("credit_card_id IS NOT NULL") }
  scope :not_rental_expired, -> { where(rental_expired: [nil, false]) }
  scope :rentals_to_expire, -> {
    time_now = Time.current
    where(rental_expired: false)
      .joins(:url_redirect)
      .where(
        "url_redirects.created_at < ? OR url_redirects.rental_first_viewed_at < ?",
        time_now - UrlRedirect::TIME_TO_WATCH_RENTED_PRODUCT_AFTER_PURCHASE,
        time_now - UrlRedirect::TIME_TO_WATCH_RENTED_PRODUCT_AFTER_FIRST_PLAY
      )
  }
  scope :for_mobile_listing, -> {
    all_success_states
    .not_is_deleted_by_buyer
    .not_is_additional_contribution
    .not_recurring_charge
    .not_is_gift_sender_purchase
    .not_refunded_except_subscriptions
    .not_chargedback_or_chargedback_reversed
    .not_is_archived_original_subscription_purchase
    .not_rental_expired
    .order(:id)
    .includes(:preorder, :purchaser, :seller, :subscription, url_redirect: { purchase: { link: [:user, :thumbnail] } })
  }
  scope :for_library, lambda {
    all_success_states
      .not_is_additional_contribution
      .not_recurring_charge
      .not_is_gift_sender_purchase
      .not_refunded_except_subscriptions
      .not_chargedback_or_chargedback_reversed
      .not_is_archived_original_subscription_purchase
      .not_is_access_revoked
  }
  scope :for_sales_api, -> {
    all_success_states_except_preorder_auth_and_gift.exclude_not_charged_except_free_trial
  }
  scope :for_sales_api_ordered_by_date, ->(subquery_details) {
    subqueries = [successful, not_charged.is_free_trial_purchase]
    subqueries_sqls = subqueries.map do |subquery|
      "(" + subquery_details.call(subquery).to_sql + ")"
    end
    from("(" + subqueries_sqls.join(" UNION ") + ") AS #{table_name}")
  }
  scope :for_displaying_installments, ->(email:) {
    all_success_states_including_test
      .can_access_content
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .not_is_gift_sender_purchase
      .where(email:)
  }

  scope :for_visible_posts, ->(purchaser_id:) {
    all_success_states
      .not_fully_refunded
      .not_chargedback_or_chargedback_reversed
      .where(purchaser_id:)
  }

  scope :paypal, -> { where(charge_processor_id: PaypalChargeProcessor.charge_processor_id) }
  scope :stripe, -> { where(charge_processor_id: StripeChargeProcessor.charge_processor_id) }

  scope :not_access_revoked_or_is_paid, -> { not_is_access_revoked.or(paid) }

  # Public: Get a JSON response representing a Purchase object
  #
  # version - Supported versions
  #           1       - initial version
  #           2       - `price` is no longer `formatted_display_price`, and is now `price_cents`.
  #                   - `link_id` has been renamed to `product_id`, and now shows the `external_id`.
  #                   - `link_name` has been renamed to `product_name`
  #                   - `custom_fields` is no longer an array containing strings `"field: value"` and instead is now a proper hash.
  #                   - `variants` is no longer an string containing the list of variants `variant: selection, variant2: selection2` and instead is now a proper hash.
  #           default - version 1
  #                   - changes made for later versions that do not change fields in previous versions may be included
  #
  # Returns a JSON representation of the Purchase
  def as_json(options = {})
    version = options[:version] || 1
    return as_json_for_admin_review if options[:admin_review]

    pundit_user = options[:pundit_user]
    json = {
      id: ObfuscateIds.encrypt(id),
      email: purchaser_email_or_email,
      seller_id: ObfuscateIds.encrypt(seller.id),
      timestamp: "#{time_ago_in_words(created_at)} ago",
      daystamp: created_at.in_time_zone(seller.timezone).to_fs(:long_formatted_datetime),
      created_at:,
      link_name: (link.name if version == 1),
      product_name: link.name,
      product_has_variants: (link.association_cached?(:variant_categories_alive) ? !link.variant_categories_alive.empty? : link.variant_categories_alive.exists?),
      price: version == 1 ? formatted_display_price : price_cents,
      gumroad_fee: fee_cents,
      is_bundle_purchase:,
      is_bundle_product_purchase:,
    }

    return json.merge!(additional_fields_for_creator_app_api) if options[:creator_app_api]

    if options[:include_variant_details]
      variants_for_json = variant_details_hash
    elsif version == 1
      variants_for_json = variants_list
    else
      variants_for_json = variant_names_hash
    end

    json.merge!(
      subscription_duration:,
      formatted_display_price:,
      transaction_url_for_seller:,
      formatted_total_price:,
      currency_symbol: symbol_for(displayed_price_currency_type),
      amount_refundable_in_currency:,
      link_id: (link.unique_permalink if version == 1),
      product_id: link.external_id,
      product_permalink: link.unique_permalink,
      refunded: stripe_refunded,
      partially_refunded: stripe_partially_refunded,
      chargedback: chargedback_not_reversed?,
      purchase_email: email,
      giftee_email:,
      gifter_email:,
      full_name: full_name.try(:strip).presence || purchaser&.name,
      street_address:,
      city:,
      state: state_or_from_ip_address,
      zip_code:,
      country: country_or_from_ip_address,
      country_iso2: Compliance::Countries.find_by_name(country)&.alpha2,
      paid: price_cents != 0,
      has_variants: !variant_names_hash.nil?,
      variants: variants_for_json,
      variants_and_quantity:,
      has_custom_fields: custom_fields.present?,
      custom_fields: version == 1 ?
        custom_fields.map { |field| "#{field[:name]}: #{field[:value]}" } :
        custom_fields.pluck(:name, :value).to_h,
      order_id: external_id_numeric,
      is_product_physical: link.is_physical,
      purchaser_id: purchaser.try(:external_id),
      is_recurring_billing: link.is_recurring_billing,
      can_contact: can_contact?,
      is_following: is_following?,
      disputed: chargedback?,
      dispute_won: chargeback_reversed?,
      is_additional_contribution:,
      discover_fee_charged: was_discover_fee_charged?,
      is_upgrade_purchase: is_upgrade_purchase?,
      ppp: ppp_info,
      is_more_like_this_recommended: recommended_by == RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION,
      is_gift_sender_purchase:,
      is_gift_receiver_purchase:,
      referrer:,
      can_revoke_access: pundit_user ? Pundit.policy!(pundit_user, [:audience, self]).revoke_access? : nil,
      can_undo_revoke_access: pundit_user ? Pundit.policy!(pundit_user, [:audience, self]).undo_revoke_access? : nil,
      can_update: pundit_user ? Pundit.policy!(pundit_user, [:audience, self]).update? : nil,
      upsell: upsell_purchase&.as_json,
      paypal_refund_expired: paypal_refund_expired?
    ).delete_if { |_, v| v.nil? }

    json[:card] = {
      visual: card_visual,
      type: card_type,

      # legacy params
      bin: nil,
      expiry_month: nil,
      expiry_year: nil
    }

    if options[:query] && options[:query].to_s == card_visual && EmailFormatValidator.valid?(card_visual)
      json[:paypal_email] = card_visual
    end

    json[:product_rating] = original_product_review.try(:rating)
    if display_product_reviews?
      json[:reviews_count] = link.reviews_count
      json[:average_rating] = link.average_rating
    end

    if subscription.present?
      json.merge!(subscription_id: subscription.external_id,
                  cancelled: subscription.cancelled_or_failed?,
                  dead: !subscription.alive?,
                  ended: subscription.ended?,
                  free_trial_ended: subscription.free_trial_ended?,
                  free_trial_ends_on: subscription.free_trial_ends_at&.to_fs(:formatted_date_abbrev_month),
                  recurring_charge: !is_original_subscription_purchase?)
    end

    if preorder.present?
      json.merge!(preorder_cancelled: preorder.is_cancelled?,
                  is_preorder_authorization:,
                  is_in_preorder_state: link.is_in_preorder_state)
    end

    if shipment.present?
      json[:shipped] = shipment.shipped?
      json[:tracking_url] = shipment.calculated_tracking_url
    end

    if offer_code.present?
      json[:offer_code] = {
        code: offer_code.code,
        displayed_amount_off: offer_code.displayed_amount_off(link.price_currency_type, with_symbol: true)
      }
      # For backwards compatibility: offer code's `name` has been renamed to `code`
      json[:offer_code][:name] = offer_code.code if version <= 2
    end

    if affiliate.present?
      json[:affiliate] = {
        email: affiliate.affiliate_user.form_email,
        amount: Money.new(affiliate_credit_cents).format(no_cents_if_whole: true, symbol: true)
      }
    end

    if was_discover_fee_charged?
      json[:discover_fee_percentage] = discover_fee_per_thousand / 10
    end

    json[:receipt_url] = receipt_url if options[:include_receipt_url]

    if options[:include_ping]
      cached_value = options[:include_ping][:value] if options[:include_ping].is_a? Hash
      json[:can_ping] = cached_value != nil ? cached_value : seller.urls_for_ping_notification(ResourceSubscription::SALE_RESOURCE_NAME).size > 0
    end

    json.merge!(license_json)

    json[:sku_id] = sku.custom_name_or_external_id if sku.present?
    json[:sku_external_id] = sku.external_id if sku.present?
    json[:formatted_shipping_amount] = formatted_shipping_amount if shipping_cents > 0
    json[:quantity] = quantity
    json[:message] = messages.unread.last if options[:unread_message]
    json
  end

  def receipt_url
    Rails.application.routes.url_helpers.receipt_purchase_url(external_id, email: email, host: "#{PROTOCOL}://#{DOMAIN}")
  end

  def as_json_for_license
    json = as_json
    json[:product_name] = json.delete :link_name
    json[:email] = json.delete :purchase_email
    if link.is_recurring_billing
      json[:subscription_ended_at] = subscription.ended_at
      json[:subscription_cancelled_at] = subscription.cancelled_at
      json[:subscription_failed_at] = subscription.failed_at
    else
      json[:chargebacked] = chargedback_not_reversed?
      json[:refunded] = stripe_refunded == true
    end
    json
  end

  def as_json_for_ifttt
    json = {
      meta: {
        id: external_id,
        timestamp: created_at.to_i
      },
      Price: formatted_total_price,
      ProductName: link.name,
      PurchaseEmail: purchaser.try(:email) || email,
      ProductDescription: link.plaintext_description,
      ProductURL: link.long_url
    }

    json[:ProductImageURL] = link.preview_url if link.preview_image_path?

    json
  end

  def as_json_for_admin_review
    refunding_users = refunds.map(&:user).compact
    {
      "email" => email,
      "created" => "#{time_ago_in_words(created_at)} ago",
      "id" => id,
      "amount" => price_cents,
      "displayed_price" => formatted_total_price,
      "formatted_gumroad_tax_amount" => formatted_gumroad_tax_amount,
      "is_preorder_authorization" => is_preorder_authorization,
      "stripe_refunded" => stripe_refunded,
      "is_chargedback" => chargedback?,
      "is_chargeback_reversed" => chargeback_reversed,
      "refunded_by" => refunding_users.map { |u| { id: u.id, email: u.email } },
      "error_code" => error_code,
      "purchase_state" => purchase_state,
      "gumroad_responsible_for_tax" => gumroad_responsible_for_tax?
    }
  end

  def email_digest
    if email.present?
      key = GlobalConfig.get("OBFUSCATE_IDS_CIPHER_KEY")
      token_data = "#{id}:#{email}"
      Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", key, token_data))
    end
  end

  def transaction_url_for_seller
    ChargeProcessor.transaction_url_for_seller(charge_processor_id, stripe_transaction_id, charged_using_gumroad_merchant_account?)
  end

  def base_product_price_cents
    return price_for_recurrence.price_cents if price_for_recurrence.present?

    is_rental ? link.rental_price_cents : link.price_cents
  end

  def charged_using_gumroad_merchant_account?
    (merchant_account&.is_managed_by_gumroad?) ||
        (charge_processor_id == StripeChargeProcessor.charge_processor_id && !charged_using_stripe_connect_account?)
  end

  def charged_using_stripe_connect_account?
    merchant_account&.is_a_stripe_connect_account?
  end

  def charged_using_paypal_connect_account?
    merchant_account&.is_a_paypal_connect_account?
  end

  def update_user_balance_in_transaction_for_affiliate
    if charged_using_gumroad_merchant_account? && using_gumroad_merchant_account_for_affiliate_user?
      true
    elsif seller_merchant_migration_enabled? && !affiliate_merchant_account&.is_managed_by_gumroad?
      false
    else
      true
    end
  end

  def seller_merchant_account_exists?
    seller&.merchant_account(charge_processor_id || StripeChargeProcessor.charge_processor_id).present?
  end

  def affiliate_merchant_account_exists?
    affiliate_user_merchant_account = merchant_account_for_affiliate_user
    affiliate_user_merchant_account && !affiliate_user_merchant_account.is_managed_by_gumroad?
  end

  def seller_merchant_migration_enabled?
    seller&.merchant_migration_enabled?
  end

  def seller_native_paypal_payment_enabled?
    seller&.native_paypal_payment_enabled?
  end

  def using_gumroad_merchant_account_for_affiliate_user?
    # Always true for now. Revisit when Stripe merchant migration is enabled.
    true
  end

  def merchant_account_for_affiliate_user
    affiliate_user = affiliate&.affiliate_user
    charge_processor_id = self.charge_processor_id || StripeChargeProcessor.charge_processor_id
    merchant_account = affiliate_user&.merchant_account(charge_processor_id)
    merchant_account || MerchantAccount.gumroad(charge_processor_id)
  end

  def refunded? = stripe_refunded?
  def chargedback? = chargeback_date.present?
  def chargedback_not_reversed? = chargedback? && !chargeback_reversed?
  def chargedback_not_reversed_or_refunded? = chargedback_not_reversed? || refunded?

  def is_following?
    Follower.active.where(email:, followed_id: seller.id).exists?
  end

  def purchase_response
    purchase_info.merge!(self.class.purchase_response(url_redirect, link, self))
  end

  def purchase_info
    self.class.purchase_info(url_redirect, link, self).merge!(variants_displayable: variants_list)
  end

  def self.purchase_response(url_redirect, link, purchase = nil)
    extra_purchase_notice = nil
    if link.is_in_preorder_state
      extra_purchase_notice = if link.is_physical
        "You'll be charged on #{displayable_release_at_date_and_time(link.preorder_link.release_at, link.user.timezone)}, and shipment will occur soon after."
      else
        "You'll get it on #{displayable_release_at_date_and_time(link.preorder_link.release_at, link.user.timezone)}."
      end
    elsif link.is_recurring_billing
      extra_purchase_notice = if link.is_physical
        "You will also receive updates over email."
      else
        "You will receive an email when there's new content."
      end
    end

    response = purchase_info(url_redirect, link, purchase).merge!(success: true,
                                                                  permalink: link.unique_permalink,
                                                                  remaining: link.remaining_for_sale_count,
                                                                  name: link.name,
                                                                  variants: link.variant_list,
                                                                  extra_purchase_notice:,
                                                                  twitter_share_url: link.twitter_share_url,
                                                                  twitter_share_text: link.social_share_text)

    ping_notification_payload = purchase.payload_for_ping_notification(url_parameters: purchase.url_parameters,
                                                                       resource_name: ResourceSubscription::SALE_RESOURCE_NAME)
    ping_notification_payload.merge(response)
  end

  def license_key
    return nil unless link.is_licensed?

    license.try(:serial)
  end

  def self.purchase_info(url_redirect, link, purchase = nil)
    json = {
      created_at: purchase.created_at,
      should_show_receipt: !purchase.is_test_purchase? && purchase.successful_and_not_reversed?(include_gift: true),
      show_view_content_button_on_product_page: purchase.show_view_content_button_on_product_page?,
      is_recurring_billing: link.is_recurring_billing,
      is_physical: link.is_physical,
      has_files: link.has_files?,
      product_id: link.external_id,
      is_gift_receiver_purchase: purchase.present? && purchase.is_gift_receiver_purchase,
      gift_receiver_text: "#{purchase.try(:gifter_email)} bought this for you.",
      is_gift_sender_purchase: purchase.present? && purchase.is_gift_sender_purchase,
      gift_sender_text: "You bought this for #{purchase&.giftee_name_or_email}.",
      content_url: purchase.has_content? ? url_redirect.try(:download_page_url) : nil,
      redirect_token: url_redirect.try(:token),
      url_redirect_external_id: url_redirect.try(:external_id),
      price: purchase.formatted_display_price,
      id: ObfuscateIds.encrypt(purchase.id),
      email: purchase.try(:email),
      email_digest: purchase.try(:email_digest),
      full_name: purchase.try(:full_name),
      view_content_button_text: view_content_button_text(link),
      is_following: purchase.try(:is_following?),
      currency_type: link.price_currency_type,
      has_third_party_analytics: link.has_third_party_analytics?("receipt"),
      non_formatted_price: Money.new(purchase.displayed_price_cents, purchase.displayed_price_currency_type).cents,
      subscription_has_lapsed: link.is_recurring_billing? && !purchase.subscription&.alive?,
      domain: DOMAIN,
      protocol: PROTOCOL,
      native_type: link.native_type,
    }

    if purchase.present?
      json[:test_purchase_notice] = "This was a test purchase — you have not been charged (you are seeing this message because you are logged in as the creator)." if purchase.is_test_purchase?
      json[:account_by_this_email_exists] = purchase.purchaser_id?
      json[:display_product_reviews] = purchase.link.display_product_reviews?
      review = purchase.original_product_review
      json[:product_rating] = review.rating if review.present?
      json[:review] = ProductReviewPresenter.new(review).review_form_props if review.present?
      json[:has_shipping_to_show] = purchase.shipping_cents > 0
      json[:shipping_amount] = purchase.formatted_shipping_amount
      json[:has_sales_tax_to_show] = purchase.was_purchase_taxable && purchase.price_cents > 0
      json[:sales_tax_amount] = Money.new(purchase.tax_in_purchase_currency,
                                          purchase.displayed_price_currency_type).format(no_cents_if_whole: true, symbol: true)
      json[:non_formatted_seller_tax_amount] = Money.new(purchase.seller_taxes_in_purchase_currency,
                                                         purchase.displayed_price_currency_type).format(no_cents_if_whole: true, symbol: false)
      json[:was_tax_excluded_from_price] = purchase.was_tax_excluded_from_price
      json[:sales_tax_label] = purchase.tax_label
      json[:has_sales_tax_or_shipping_to_show] = (purchase.was_purchase_taxable && purchase.price_cents > 0) || purchase.shipping_cents > 0
      json[:total_price_including_tax_and_shipping] = purchase.formatted_total_transaction_amount
      json[:quantity] = purchase.quantity
      json[:show_quantity] = purchase.quantity > 1
      json[:license_key] = purchase.license_key if purchase.license.present?
      if purchase.shipment.present?
        json[:shipped] = purchase.shipment.shipped?
        json[:tracking_url] = purchase.shipment.calculated_tracking_url
      end
      if link.is_tiered_membership?
        first_tier_name = purchase.variant_attributes.first&.name
        json[:membership] = {
          tier_name: first_tier_name == "Untitled" ? purchase.link.name : first_tier_name,
          tier_description: purchase.variant_attributes.first&.description,
          manage_url: Rails.application.routes.url_helpers.manage_subscription_url(purchase.subscription.external_id, host: "#{PROTOCOL}://#{DOMAIN}"),
        }
      end
      json[:enabled_integrations] = Integration.enabled_integrations_for(purchase)
    end
    if purchase.is_bundle_purchase?
      json[:bundle_products] = purchase.product_purchases.map do |product_purchase|
        {
          id: product_purchase.link.external_id,
          content_url: product_purchase.has_content? ? product_purchase.url_redirect.try(:download_page_url) : nil,
        }
      end
    end

    json
  end

  def successful_and_not_reversed?(include_gift: false)
    success_states = include_gift ? Purchase::ALL_SUCCESS_STATES : Purchase::NON_GIFT_SUCCESS_STATES
    !stripe_refunded? && chargeback_date.nil? && purchase_state.in?(success_states)
  end

  def successful_and_valid?
    if link.is_recurring_billing
      successful_and_not_reversed? && subscription.alive?
    else
      successful_and_not_reversed?
    end
  end

  def has_content?
    return false if url_redirect.nil?
    return false if webhook_failed
    return false if link.has_stampable_pdfs? && !url_redirect.is_done_pdf_stamping

    true
  end

  def show_view_content_button_on_product_page?
    return true if link.is_tiered_membership? && url_redirect.present?

    has_content?
  end

  def is_preorder_charge?
    preorder.present? && !is_preorder_authorization
  end

  def purchaser_email_or_email
    if purchaser.try(:email).present?
      purchaser.email
    else
      email
    end
  end

  # Public: Get the shipping amount in the purchase's currency.
  def shipping_in_purchase_currency
    usd_cents_to_currency(link.price_currency_type, shipping_cents, rate_converted_to_usd)
  end

  # Public: Get the tax amount in the purchase's currency.
  def tax_in_purchase_currency
    usd_cents_to_currency(link.price_currency_type, tax_amount, rate_converted_to_usd)
  end

  def tax_amount
    (gumroad_tax_cents || 0) > 0 ? gumroad_tax_cents : tax_cents
  end

  def non_refunded_tax_amount
    (gumroad_tax_cents || 0) > 0 ? (gumroad_tax_cents - gumroad_tax_refunded_cents) : tax_cents
  end

  def seller_tax_amount
    tax_cents || 0
  end

  # Public: Get the tax the seller collects in the purchase's currency.
  def seller_taxes_in_purchase_currency
    tax_amount = seller_tax_amount
    usd_cents_to_currency(link.price_currency_type, tax_amount, rate_converted_to_usd)
  end

  def tax_label(include_tax_rate: true)
    return unless has_tax_label?

    if Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country) ||
       Compliance::Countries::NORWAY_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country) ||
       Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(zip_tax_rate&.country) ||
       Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.include?(zip_tax_rate&.country)
      label = "VAT"
      label += " (#{(zip_tax_rate.combined_rate * 100).to_i}%)" if include_tax_rate
      label
    elsif Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country)
      label = "GST"
      label += " (#{(zip_tax_rate.combined_rate * 100).to_i}%)" if include_tax_rate
      label
    else
      label = "Sales tax"
      if include_tax_rate && !was_tax_excluded_from_price
        label += " (included)"
      end
      label
    end
  end

  def tax_label_with_creator_tax_info
    return tax_label if zip_tax_rate.nil? || zip_tax_rate.user_id.nil? || zip_tax_rate.invoice_sales_tax_id.nil?

    tax_label + " (Creator tax ID: #{zip_tax_rate.invoice_sales_tax_id})"
  end

  def seller_tax_label
    return unless has_tax_label?

    if Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country)
      if was_tax_excluded_from_price
        "EU VAT"
      else
        "EU VAT (included)"
      end
    elsif Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(zip_tax_rate&.country) ||
          Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.include?(zip_tax_rate&.country)
      if was_tax_excluded_from_price
        "VAT"
      else
        "VAT (included)"
      end
    elsif Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country)
      if was_tax_excluded_from_price
        "GST"
      else
        "GST (included)"
      end
    elsif Compliance::Countries::NORWAY_VAT_APPLICABLE_COUNTRY_CODES.include?(zip_tax_rate&.country)
      if was_tax_excluded_from_price
        "Norway VAT"
      else
        "Norway VAT (included)"
      end
    else
      if was_tax_excluded_from_price
        "Sales tax"
      else
        "Sales tax (included)"
      end
    end
  end

  def has_tax_label?
    # We *should* be able to just check for was_purchase_taxable here.
    # But it's not set in a callback, so we're also checking the tax fields to be sure.
    was_purchase_taxable || gumroad_tax_cents > 0 || tax_cents > 0
  end

  def total_transaction_amount_for_gumroad_cents
    fee_cents + affiliate_credit_cents + gumroad_tax_cents
  end

  def formatted_total_price
    amount_in_purchase_currency = usd_cents_to_currency(displayed_price_currency_type, price_cents, rate_converted_to_usd)
    format_price_in_cents(amount_in_purchase_currency)
  end

  def formatted_tax_amount
    format_price_in_cents(tax_in_purchase_currency)
  end

  def formatted_seller_tax_amount
    format_price_in_cents(seller_taxes_in_purchase_currency)
  end

  def formatted_display_price
    format_price_in_cents(displayed_price_cents)
  end

  def formatted_display_price_per_unit
    format_price_in_cents(displayed_price_per_unit_cents)
  end

  def formatted_total_display_price_per_unit
    format_price_in_cents(displayed_price_per_unit_cents + (commission&.completion_price_cents || 0) - (tip&.value_cents || 0))
  end

  def total_in_purchase_currency
    usd_cents_to_currency(displayed_price_currency_type, total_transaction_cents, rate_converted_to_usd)
  end

  def formatted_total_transaction_amount(format: :long)
    format_price_in_cents(total_in_purchase_currency, format:)
  end

  def formatted_non_refunded_total_transaction_amount
    total_in_product_currency = usd_cents_to_currency(displayed_price_currency_type, non_refunded_total_transaction_amount, rate_converted_to_usd)
    format_price_in_cents(total_in_product_currency)
  end

  def non_refunded_total_transaction_amount
    total_transaction_cents - gumroad_tax_refunded_cents
  end

  def formatted_gumroad_tax_amount
    tax_in_product_currency = usd_cents_to_currency(displayed_price_currency_type, gumroad_tax_cents, rate_converted_to_usd)
    format_price_in_cents(tax_in_product_currency)
  end

  def formatted_shipping_amount
    format_price_in_cents(shipping_in_purchase_currency)
  end

  def formatted_affiliate_credit_amount
    Money.new(affiliate_credit_cents).format(symbol: true)
  end

  def format_price_in_currency(price_cents)
    price_cents_in_currency = usd_cents_to_currency(displayed_price_currency_type, price_cents, rate_converted_to_usd)
    format_price_in_cents(price_cents_in_currency)
  end

  def find_enabled_integration(integration_name)
    if variant_attributes.present? && !link.is_physical?
      variant_attributes.first.find_integration_by_name(integration_name)
    else
      link.find_integration_by_name(integration_name)
    end
  end

  # Public: Returns the lowest amount the buyer must be paying for this purchase to be valid.
  # There are special cases for recurring subs charges and pre-order charges, since for these two types of purchases
  # the minimum amount is already calculated and stored in the original subs purchase and pre-order authorization
  # purchase respectively. This way the seller can change the product's price and/or varaints' prices and old
  # subscribers/pre-orderers will be charged the amount that they were shown originally.
  #
  # For other purchases the minimum amount is the price of the product plus the price of the chosen variants
  # minus the amount the buyer saves by using an offer code. Note that the buyer can pay more than this minimum
  # amount if the product is variable pricing.
  #
  # If this is an "upgrade" purchase, i.e. a one-off subscription purchase to bump up to a more expensive tier, this
  # includes a discount for the amount already paid towards the current subscription (`prorated_discount_price_cents`).
  #
  # If this is a "downgrade" purchase (i.e. we are applying a `subscription_plan_change`),
  # we will have recorded the agreed-upon price at the time, which will be set to
  # `perceived_price_cents`, and we will return that.
  #
  # Returns the minimum amount in the product's currency.
  def minimum_paid_price_cents
    return 0 if is_gift_receiver_purchase
    return perceived_price_cents if perceived_price_cents.present? && is_applying_plan_change

    if is_recurring_subscription_charge
      minimum_price = subscription.current_subscription_price_cents
    elsif is_preorder_charge?
      minimum_price = preorder.authorization_purchase.displayed_price_cents
    else
      minimum_price_cents = minimum_paid_price_cents_per_unit_before_discount - offer_amount_off(minimum_paid_price_cents_per_unit_before_discount)
      # We want an offer code to apply to every quantity separately ($2 offer code on 2 CDs = $4 off).
      minimum_price_cents *= quantity

      minimum_price_cents *= purchasing_power_parity_factor if is_purchasing_power_parity_discounted? && link.purchasing_power_parity_enabled? && original_offer_code.blank?

      minimum_price = minimum_price_cents

      if is_commission_completion_purchase
        minimum_price *= (1 - Commission::COMMISSION_DEPOSIT_PROPORTION)
      elsif link.native_type == Link::NATIVE_TYPE_COMMISSION
        minimum_price *= Commission::COMMISSION_DEPOSIT_PROPORTION
      elsif is_installment_payment
        minimum_price = calculate_installment_payment_price_cents(minimum_price_cents)
      end

      # We allow offer codes that are larger than the price of the product. In that case minimum_price_cents could be negative here. Set it to 0.
      if original_offer_code.present? && minimum_price_cents < 0
        minimum_price = 0
      # If a PPP discount decreases the price to a value lower than the minimum, round the price up to the minimum.
      elsif is_purchasing_power_parity_discounted && minimum_price_cents != 0 && minimum_price_cents < link.currency["min_price"]
        minimum_price = link.currency["min_price"]
      end
    end

    if is_upgrade_purchase && prorated_discount_price_cents
      minimum_price -= prorated_discount_price_cents
    end

    minimum_price.round
  end

  def minimum_paid_price_cents_per_unit_before_discount
    base_product_price_cents + variant_extra_cost
  end

  def payment_cents
    price_cents - fee_cents
  end

  def increment_affiliates_balance!
    return unless affiliate_credit_cents > 0

    create_affiliate_balances!

    return if using_gumroad_merchant_account_for_affiliate_user?

    if merchant_account_for_affiliate_user&.charge_processor_merchant_id
      logger.info("Transferring affiliate Credits for: #{id}")

      StripeTransferAffiliateCredits.transfer_funds_to_account(
        description: "Affiliate Credits:#{statement_description}",
        transfer_group: id,
        stripe_account_id: merchant_account_for_affiliate_user.charge_processor_merchant_id,
        amount_cents: affiliate_credit_cents,
        related_charge_id: stripe_transaction_id
      )
    else
      MerchantRegistrationMailer.account_needs_registration_to_user(
        affiliate.id,
        StripeChargeProcessor.charge_processor_id
      ).deliver_later(queue: "critical")
    end
  end

  def create_affiliate_balances!
    affiliate_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_affiliate(
      flow_of_funds:,
      issued_affiliate_cents: affiliate_credit_cents
    )

    affiliate_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_affiliate(
      flow_of_funds:,
      issued_affiliate_cents: affiliate_credit_cents
    )

    affiliate_balance_transaction = BalanceTransaction.create!(
      user: affiliate.affiliate_user,
      merchant_account: affiliate_merchant_account,
      purchase: self,
      issued_amount: affiliate_issued_amount,
      holding_amount: affiliate_holding_amount,
      update_user_balance: update_user_balance_in_transaction_for_affiliate
    )

    self.affiliate_credit = AffiliateCredit.create!(
      purchase: self,
      affiliate:,
      affiliate_balance: affiliate_balance_transaction.balance,
      affiliate_amount_cents: affiliate_credit_cents,
      affiliate_fee_cents: determine_affiliate_fee_cents.ceil,
    )
  end

  def increment_sellers_balance!
    return if price_cents == 0

    increment_affiliates_balance!

    return unless charged_using_gumroad_merchant_account?

    seller_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_seller(
      flow_of_funds:,
      issued_net_cents: payment_cents - affiliate_credit_cents
    )

    seller_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_seller(
      flow_of_funds:,
      issued_net_cents: payment_cents - affiliate_credit_cents
    )

    seller_balance_transaction = BalanceTransaction.create!(
      user: seller,
      merchant_account:,
      purchase: self,
      issued_amount: seller_issued_amount,
      holding_amount: seller_holding_amount,
      update_user_balance: charged_using_gumroad_merchant_account?
    )

    self.purchase_success_balance = seller_balance_transaction.balance
    save!
  end

  def notify_seller!
    return if webhook_failed || is_bundle_product_purchase? || is_commission_completion_purchase?

    # Dont send the seller email if this is the original charge purchase for a preorder, because we send the preorder summary email
    # once all preorders have been charged once.
    return if preorder.present? && preorder.purchases.count == 2

    after_commit do
      next if destroyed?
      ContactingCreatorMailer.notify(id).deliver_later(queue: "critical", wait: 3.seconds)
    end
  end

  def notify_affiliate!
    return unless affiliate.affiliate_user.enable_payment_email?
    return if affiliate_credit_cents == 0

    after_commit do
      next if destroyed?
      AffiliateMailer.notify_affiliate_of_sale(id).deliver_later
    end
  end

  def create_product_affiliate
    return unless affiliate.present? && affiliate.global? && link.product_affiliates.where(affiliate_id: affiliate.id).none?
    link.affiliates << affiliate
  end

  def create_url_redirect_for_failed_purchase
    # Creating a url redirect for purchases which are failed but will appear to have gone through to buyer. create_url_redirect! is usually called
    # on the state machine transition to successful, so we are manually calling this method for failed purchases which are being fake.
    # The buyer is assumed to be committing fraudulent behavior so the rendering of the "product" to it doesn't really matter as they will
    # not be consuming it anyway.
    create_url_redirect!
  end

  def create_artifacts_and_send_receipt!
    if link.is_bundle
      self.update!(is_bundle_purchase: true)
      link.bundle_products.alive.each do |bundle_product|
        Purchase::CreateBundleProductPurchaseService.new(self, bundle_product).perform
      end
      purchase_custom_fields.reload
    end
    create_commission! if is_commission_deposit_purchase?
    create_url_redirect!
    create_license!
    send_receipt
  end

  def create_url_redirect!
    return if url_redirect
    return if is_gift_sender_purchase
    return if is_commission_completion_purchase?

    self.url_redirect = UrlRedirect.create!(purchase: self, link:, is_rental:)
  end

  def create_license!
    return if is_gift_sender_purchase
    return unless link.is_licensed
    return if license.present?

    license = create_license
    link.licenses << license
    license
  end

  def license
    return subscription.original_purchase.license if is_recurring_subscription_charge

    super
  end

  def create_commission!
    return unless is_commission_deposit_purchase
    return if commission.present?

    Commission.create!(deposit_purchase: self, status: Commission::STATUS_IN_PROGRESS)
  end

  def commission
    if is_commission_deposit_purchase
      commission_as_deposit
    elsif is_commission_completion_purchase
      commission_as_completion
    end
  end

  def from_foreign_currency?
    !displayed_price_currency_type.to_s.casecmp("usd").zero?
  end

  def displayed_price_currency_type
    self[:displayed_price_currency_type].to_sym
  end

  def shipping_information
    return {} unless link.require_shipping

    shipping_info = {}
    %w[full_name street_address country state zip_code city].each do |attr|
      shipping_info[attr.to_sym] = send(attr.to_sym) || ""
    end

    shipping_info
  end

  def gross_amount_refunded_cents
    amount_refunded_cents + gumroad_tax_refunded_cents
  end

  def amount_refunded_cents
    refunds.sum(:amount_cents)
  end

  def fee_refunded_cents
    refunds.sum(:fee_cents)
  end

  def tax_refunded_cents
    refunds.sum(:creator_tax_cents)
  end

  def gumroad_tax_refunded_cents
    refunds.sum(:gumroad_tax_cents)
  end

  def gross_amount_refundable_cents
    amount_refundable_cents + gumroad_tax_refundable_cents
  end

  def amount_refundable_cents
    return 0 unless charge_processor_id.in?(ChargeProcessor.charge_processor_ids) # We can't refund purchases where we've removed support for the payment method
    price_cents - amount_refunded_cents
  end

  def amount_refundable_in_currency
    amount_in_cents = usd_cents_to_currency(link.price_currency_type, amount_refundable_cents, rate_converted_to_usd)
    Money.new(amount_in_cents, displayed_price_currency_type).format(no_cents_if_whole: true, symbol: false)
  end

  def amount_refundable_cents_in_currency
    usd_cents_to_currency(link.price_currency_type, amount_refundable_cents, rate_converted_to_usd)
  end

  def paypal_refund_expired?
    created_at < 6.months.ago && card_type == CardType::PAYPAL
  end

  def refunding_amount_cents(amount)
    amount_cents = (amount.to_d * unit_scaling_factor(displayed_price_currency_type)).to_i
    get_usd_cents(displayed_price_currency_type, amount_cents, rate: rate_converted_to_usd)
  end

  def gumroad_tax_refundable_cents
    ActiveRecord::Base.connection.stick_to_primary!
    gumroad_tax_cents - gumroad_tax_refunded_cents
  end

  def mark_giftee_purchase_as_refunded(is_partially_refunded: false)
    giftee_purchase = gift_given.present? ? gift_given.giftee_purchase : nil
    return if giftee_purchase.nil?

    if is_partially_refunded
      giftee_purchase.stripe_partially_refunded = true
    else
      giftee_purchase.stripe_refunded = true
    end

    giftee_purchase.save!
  end

  def mark_giftee_purchase_as_chargeback
    giftee_purchase = gift_given.present? ? gift_given.giftee_purchase : nil
    return if giftee_purchase.nil?

    giftee_purchase.chargeback_date = DateTime.current
    giftee_purchase.save!
  end

  def mark_giftee_purchase_as_chargeback_reversed
    giftee_purchase = gift_given.present? ? gift_given.giftee_purchase : nil
    return if giftee_purchase.nil?

    giftee_purchase.chargeback_reversed = true
    giftee_purchase.save!
  end

  def mark_product_purchases_as_chargedback!
    return unless is_bundle_purchase?
    product_purchases.each do |product_purchase|
      product_purchase.update!(chargeback_date: DateTime.current)
    end
  end

  def mark_product_purchases_as_chargeback_reversed!
    return unless is_bundle_purchase?
    product_purchases.each do |product_purchase|
      product_purchase.update!(chargeback_reversed: true)
    end
  end

  # Public: Sets the price on the purchase object and attempts to charge the user's card.
  # Attaches a resulting `charge_intent` to the purchase. The charge intent can succeed immediately
  # (if no user action is required), fail immediately, or require user action.
  #
  # Params:
  #   - `off_session`: if set to true, it means there's no user in session and customer authentication is impossible.
  #                    We should attempt the charge and fail immediately if it requires user action.
  #
  #                    if set to `false`, it means we have a user in session and if charge requires further authentication,
  #                    the method should succeed and attach a `charge_intent` with `requires_action? == true`.
  def process!(off_session: true)
    prepare_for_charge!
    charge!(off_session:)
  end

  def charge!(off_session: true)
    return if chargeable.nil?

    self.charge_intent = create_charge_intent(chargeable, off_session:)
    return if errors.present?

    save_charge_data(charge_intent.charge, chargeable:) if charge_intent.succeeded?

    unless charge_intent.succeeded? || charge_intent.requires_action? || (charge_intent.is_a?(StripeChargeIntent) && charge_intent.processing?)
      errors.add :base, "Sorry, something went wrong."
    end
  end

  def processor_payment_intent_id = processor_payment_intent&.intent_id

  def confirm_charge_intent!
    return if processor_payment_intent_id.blank?

    self.charge_intent = ChargeProcessor.confirm_payment_intent!(merchant_account, processor_payment_intent_id)

    if charge_intent.succeeded?
      save_charge_data(charge_intent.charge)
    else
      errors.add :base, "Sorry, something went wrong."
    end

  rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
    logger.error "Error while confirming charge intent: #{e.message} in purchase: #{external_id}"
    errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
    self.error_code = PurchaseErrorCode::STRIPE_UNAVAILABLE
    nil
  rescue ChargeProcessorCardError => e
    self.stripe_error_code = e.error_code
    self.stripe_transaction_id = e.charge_id
    self.was_zipcode_check_performed = true if e.error_code == "incorrect_zip"
    logger.info "Error while confirming charge intent: #{e.message} in purchase: #{external_id}"
    errors.add :base, PurchaseErrorCode.customer_error_message(e.message)
    nil
  end

  # Attempts to cancel charge intent, assuming it hasn't succeeded or failed yet.
  # Returns `true` if successfully cancelled, `false` otherwise.
  def cancel_charge_intent
    return false if processor_payment_intent_id.nil?

    begin
      cancel_charge_intent!
      true
    rescue ChargeProcessorError => e
      logger.info "Error while cancelling charge intent: #{e.message} in purchase: #{id}"
      false
    end
  end

  # Attempts to cancel charge intent, assuming it hasn't succeeded or failed yet.
  # Raises a ChargeProcessorError error if there's an error canceling the charge intent.
  def cancel_charge_intent!
    ChargeProcessor.cancel_payment_intent!(merchant_account, processor_payment_intent_id)
    Purchase::MarkFailedService.new(self).perform
  end

  # Attempts to cancel setup intent, assuming it hasn't succeeded or failed yet.
  # Raises a ChargeProcessorError error if there's an error canceling the setup intent.
  def cancel_setup_intent!
    ChargeProcessor.cancel_setup_intent!(merchant_account, processor_setup_intent_id)
    Purchase::MarkFailedService.new(self).perform
  end

  def set_price_and_rate
    if offer_code.present? && !has_cached_offer_code?
      self.build_purchase_offer_code_discount(offer_code:, offer_code_amount: offer_code.amount, offer_code_is_percent: offer_code.is_percent?,
                                              pre_discount_minimum_price_cents: minimum_paid_price_cents_per_unit_before_discount,
                                              duration_in_months: link.is_tiered_membership? ? offer_code.duration_in_months : nil)
    end

    self.build_purchasing_power_parity_info(factor: purchasing_power_parity_factor) if is_purchasing_power_parity_discounted? && purchasing_power_parity_factor < 1

    self.displayed_price_cents = determine_customized_price_cents || calculate_price_range_cents || minimum_paid_price_cents
    self.displayed_price_currency_type = link.price_currency_type
    self.price_cents = displayed_price_usd_cents
    self.rate_converted_to_usd = get_rate(displayed_price_currency_type)
    self.total_transaction_cents = self.price_cents
    self.affiliate_credit_cents = determine_affiliate_balance_cents
    self.tax_cents = 0
    self.gumroad_tax_cents = 0
    self.shipping_cents = 0
    self.fee_cents = 0
  end

  def prepare_for_charge!
    self.chargeable = process_without_charging!
  end

  def update_balance_and_mark_successful!
    if is_test_purchase?
      set_succeeded_at
      mark_test_successful!
    elsif is_free_trial_purchase?
      mark_not_charged!
    elsif is_gift_receiver_purchase?
      mark_gift_receiver_purchase_successful!
    else
      set_succeeded_at
      increment_sellers_balance!
      mark_successful!
    end
  end

  def requires_sca?
    setup_intent&.requires_action? || charge_intent&.requires_action?
  end

  def time_fields
    fields = attributes.keys.keep_if { |key| key.include?("_at") && send(key) }
    fields << "chargeback_date" if chargeback_date
    fields
  end

  def process_refund_or_chargeback_for_affiliate_credit_balance(flow_of_funds, refund: nil, dispute: nil, refund_cents: 0, fee_cents: 0)
    return if affiliate_credit_cents == 0 || refund_cents == 0

    affiliate_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_affiliate(
      flow_of_funds:,
      issued_affiliate_cents: -1 * refund_cents
    )

    affiliate_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_affiliate(
      flow_of_funds:,
      issued_affiliate_cents: -1 * refund_cents
    )

    affiliate_balance_transaction = BalanceTransaction.create!(
      user: affiliate_credit.affiliate_user,
      merchant_account: affiliate_merchant_account,
      refund:,
      dispute:,
      issued_amount: affiliate_issued_amount,
      holding_amount: affiliate_holding_amount,
      update_user_balance: update_user_balance_in_transaction_for_affiliate
    )

    if refund
      affiliate_credit.affiliate_credit_refund_balance = affiliate_balance_transaction.balance
    elsif dispute
      affiliate_credit.affiliate_credit_chargeback_balance = affiliate_balance_transaction.balance
    end
    affiliate_credit.save!

    if affiliate_credit_cents != refund_cents
      affiliate_partial_refunds.create!(
        total_credit_cents: affiliate_credit_cents,
        amount_cents: refund_cents,
        fee_cents:,
        balance: affiliate_balance_transaction.balance,
        seller:,
        affiliate:,
        affiliate_user: affiliate.affiliate_user,
        affiliate_credit:,
      )
    end
  end

  def process_refund_or_chargeback_for_purchase_balance(flow_of_funds, refund: nil, dispute: nil, refund_cents: 0)
    return if refund_cents == 0
    logger.info("process_refund_or_chargeback_for_purchase_balance::flow_of_funds::#{flow_of_funds.inspect}")
    logger.info("process_refund_or_chargeback_for_purchase_balance::refund::#{refund.inspect}")
    logger.info("process_refund_or_chargeback_for_purchase_balance::dispute::#{dispute.inspect}")
    return unless charged_using_gumroad_merchant_account?

    seller_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_seller(
      flow_of_funds:,
      issued_net_cents: -1 * refund_cents
    )

    seller_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_seller(
      flow_of_funds:,
      issued_net_cents: -1 * refund_cents
    )

    seller_balance_transaction = BalanceTransaction.create!(
      user: seller,
      merchant_account:,
      refund:,
      dispute:,
      issued_amount: seller_issued_amount,
      holding_amount: seller_holding_amount,
      update_user_balance: charged_using_gumroad_merchant_account?
    )

    if refund
      self.purchase_refund_balance = seller_balance_transaction.balance
    elsif dispute
      self.purchase_chargeback_balance = seller_balance_transaction.balance
    end
    save!
  end

  def decrement_balance_for_refund_or_chargeback!(flow_of_funds, refund: nil, dispute: nil)
    return unless seller_balance_update_eligible?
    if (dispute && !stripe_partially_refunded) || [price_cents, total_transaction_cents].include?(refund&.amount_cents)
      # Short circuit for full refund, or dispute
      seller_refund_cents = payment_cents - affiliate_credit_cents
      affiliate_refund_cents = affiliate_credit_cents
      affiliate_refund_fee_cents = affiliate_credit&.fee_cents || 0
    else
      # refund.amount_cents = all inclusive, seller, affiliate, fee_cent, etc. Separate them out
      if dispute
        decrement_amount_cents = amount_refundable_cents
        refunded_fee_cents = ((fee_cents.to_f / price_cents.to_f) * decrement_amount_cents).floor
      else
        decrement_amount_cents = refund.amount_cents
        refunded_fee_cents = refund.fee_cents
      end
      seller_refund_cents = decrement_amount_cents - refunded_fee_cents
      if affiliate_credit_cents == 0
        affiliate_refund_cents = 0
        affiliate_refund_fee_cents = 0
      else
        # We use decrement_amount_cents instead of seller_refund_cents here. This is because
        # determine_affiliate_balance_cents makes use of displayed_price_cents and not payment_cents
        affiliate_cut = affiliate_credit.basis_points / 10_000.0
        affiliate_refund_fee_cents = affiliate_credit.fee_cents == 0 ? 0 : (affiliate_cut * refunded_fee_cents).floor
        affiliate_refund_cents = (affiliate_cut * decrement_amount_cents).ceil - affiliate_refund_fee_cents
        seller_refund_cents = seller_refund_cents - affiliate_refund_cents - affiliate_refund_fee_cents
      end
    end

    process_refund_or_chargeback_for_affiliate_credit_balance(flow_of_funds, refund:, dispute:, refund_cents: affiliate_refund_cents, fee_cents: affiliate_refund_fee_cents)
    process_refund_or_chargeback_for_purchase_balance(flow_of_funds, refund:, dispute:, refund_cents: seller_refund_cents)
  end

  def variant_extra_cost
    return 0 if variant_attributes.empty?

    if link.is_tiered_membership
      variant_attributes.map do |variant|
        # look for variant price with given subscription_duration
        price = variant.prices.alive.is_buy.find_by(recurrence: subscription_duration)
        if !price.present? && original_price.present? && original_price.recurrence == subscription_duration
          # if purchase's original price has been deleted, still allow the user to use that deleted price
          price = variant.prices.is_buy.find_by(recurrence: subscription_duration)
        end
        price && price.price_cents ? price.price_cents : 0
      end.sum
    else
      variant_attributes.map(&:price_difference_cents).compact.sum
    end
  end

  # Public: Returns the sku for this purchase if one exists.
  #
  # Note that purchases of sku-enabled products have one SKU only.
  def sku
    variant_attributes.first.is_a?(Sku) ? variant_attributes.first : nil
  end

  # Public: Returns the custom sku (if present) or external id for this purchase if the product is sku-enabled; otherwise a special product id is returned.
  #
  # If the product has no skus (i.e. the product is not sku-enabled or it is but has no variants), then the
  # sku id of the purchase will be "pid_#{external_product_id}".
  def sku_custom_name_or_external_id
    if sku.present?
      sku.custom_name_or_external_id
    elsif link.is_physical && variant_attributes.first.present?
      variant_attributes.first.external_id
    else
      "#{SKU_ID_PREFIX_FOR_PRODUCT_WITH_NO_SKUS}#{link.external_id}"
    end
  end

  def variant_names_hash
    return nil if variant_attributes.blank?

    if sku.present?
      sku_category_name = sku.sku_category_name
      { sku_category_name.to_s => sku.name }
    else
      variant_attributes.each_with_object({}) do |variant, result|
        result[variant.variant_category.title] = variant.name
        result
      end
    end
  end

  def variant_details_hash
    return {} if variant_attributes.blank?


    if sku.present?
      variant_attributes.each_with_object({}) do |sku, result|
        result[sku.sku_category_name.to_s] = {
          is_sku: true,
          title: sku.sku_category_name,
          selected_variant: {
            id: sku.external_id,
            name: sku.name
          }
        }
      end
    else
      variant_attributes.each_with_object({}) do |variant, result|
        result[variant.variant_category.external_id] = {
          title: variant.variant_category.title,
          selected_variant: {
            id: variant.external_id,
            name: variant.name
          }
        }
      end
    end
  end

  def variant_names
    return nil if variant_attributes.not_is_default_sku.blank?

    variant_attributes.where.not(name: "Untitled").map(&:name)
  end

  def variants_list
    variants_for_display = if variant_attributes.loaded?
      variant_attributes.reject(&:is_default_sku?)
    else
      variant_attributes.not_is_default_sku
    end
    variants_displayable(variants_for_display)
  end

  def variants_and_quantity
    variants_and_quantity_displayable(variant_attributes.not_is_default_sku, quantity)
  end

  def is_recurring_subscription_charge
    subscription.present? && !is_original_subscription_purchase && !is_gift_receiver_purchase
  end

  def touch_variants_if_limited_quantity
    variant_attributes.each do |variant|
      variant.touch if variant.max_purchase_count.present? || link.max_purchase_count.present?
    end
  end

  def has_active_subscription?
    subscription.alive?(include_pending_cancellation: false)
  end

  def has_downloadable_pdf?
    url_redirect.present? && link.has_filetype?("pdf")
  end

  def has_downloadable_mobi?
    url_redirect.present? && link.has_filetype?("mobi")
  end

  def gift
    if is_gift_sender_purchase
      gift_given
    elsif is_gift_receiver_purchase
      gift_received
    end
  end

  def gifter_email
    gift&.gifter_email
  end

  def giftee_email
    gift&.giftee_email
  end

  def giftee_name_or_email
    if gift&.is_recipient_hidden?
      is_gift_receiver_purchase ? purchaser.name_or_username : gift.giftee_purchase.purchaser.name_or_username
    else
      giftee_email
    end
  end

  def gift_note
    gift&.gift_note
  end

  def gifter_full_name
    # TODO: don't check require_shipping; this is really hacky.
    # we check require_shipping here because if the buyer entered shipping info,
    # the full name will be the giftee's name, not the gifter's.
    full_name.present? && !link.require_shipping ? full_name : nil
  end

  def paid?
    self.price_cents > 0
  end

  def does_not_count_towards_max_purchases
    is_recurring_subscription_charge || is_additional_contribution || is_preorder_charge? || is_gift_receiver_purchase || is_updated_original_subscription_purchase || is_commission_completion_purchase
  end

  # Public: Determine if this purchase is a test purchase by the links owner.
  def is_test_purchase?
    link.user == purchaser
  end

  # Public: Return json information about this purchase for the mobile api.
  def json_data_for_mobile(options = {})
    if url_redirect.present?
      json_data = url_redirect.product_json_data
    elsif preorder.present?
      json_data = preorder.mobile_json_data
    else
      json_data = link.as_json(mobile: true)
      json_data[:purchase_id] = external_id
      json_data[:purchased_at] = created_at
      json_data[:product_updates_data] = update_json_data_for_mobile
      json_data[:user_id] = purchaser.external_id if purchaser
      json_data[:is_archived] = is_archived
      json_data[:custom_delivery_url] = nil # Deprecated
    end

    if subscription.present?
      json_data[:subscription_data] = {
        id: subscription.external_id,
        subscribed_at: subscription.created_at.as_json,
        ended_at: subscription.deactivated_at.as_json,
        ended_reason: subscription.termination_reason,
      }
    end

    json_data[:purchase_email] = email.presence || purchaser&.email.presence
    json_data[:quantity] = quantity
    json_data[:order_id] = external_id_numeric
    json_data[:full_name] = full_name.try(:strip).presence || purchaser&.name

    json_data[:currency_symbol] = symbol_for(displayed_price_currency_type)
    json_data[:amount_refundable_in_currency] = amount_refundable_in_currency
    json_data[:refund_fee_notice_shown] = seller&.refund_fee_notice_shown? || false
    json_data[:product_rating] = original_product_review.try(:rating)

    json_data[:refunded] = stripe_refunded?
    json_data[:partially_refunded] = stripe_partially_refunded
    json_data[:chargedback] = chargedback_not_reversed?

    if options[:include_sale_details]
      json_data[:variants] = variant_details_hash if variant_details_hash.present?
      json_data[:upsell] = upsell_purchase.as_json if upsell_purchase.present?

      if sku.present?
        json_data[:sku_id] = sku.custom_name_or_external_id
        json_data[:sku_external_id] = sku.external_id
      end

      if shipment.present?
        json_data[:shipped] = shipment.shipped?
        json_data[:tracking_url] = shipment.calculated_tracking_url
        json_data[:shipping_address] = { full_name:, street_address:, city:, state:, zip_code:, country: }
      end

      if offer_code.present?
        json_data[:offer_code] = {
          code: offer_code.code,
          displayed_amount_off: offer_code.displayed_amount_off(link.price_currency_type, with_symbol: true)
        }
      end

      if affiliate.present?
        json_data[:affiliate] = {
          email: affiliate.affiliate_user.form_email,
          amount: Money.new(affiliate_credit_cents).format(no_cents_if_whole: true, symbol: true)
        }
      end

      json_data[:ppp] = ppp_info if ppp_info.present?
    end

    json_data
  end

  def update_json_data_for_mobile
    return [] if subscription.present? && !subscription.alive? && link.block_access_after_membership_cancellation?

    all_purchases_of_product = link.sales.for_displaying_installments(email:)

    posts = self.class.product_installments(purchase_ids: all_purchases_of_product.pluck(:id))

    posts.map { |post| post.installment_mobile_json_data(purchase: self) }.compact
  end

  # Public: Return all installments the customer should see on the content page for a given purchase.
  def product_installments
    self.class.product_installments(purchase_ids: [id])
  end

  def self.product_installments(purchase_ids:)
    return [] if purchase_ids.blank?

    purchases = Purchase.includes(:link).where(id: purchase_ids)
    product_ids = purchases.pluck(:link_id).uniq
    variant_ids = BaseVariant.joins(:purchases).where("purchases.id IN (?)", purchase_ids).select("base_variants.id")
    seller_ids = purchases.map(&:seller_id)

    check_filters = lambda do |posts|
      posts.select do |post|
        purchases.reduce(false) do |select_post, purchase|
          select_post || post.purchase_passes_filters(purchase)
        end
      end
    end

    check_filters_for_past_posts = lambda do |posts|
      posts.select do |post|
        purchases.reduce(false) do |select_post, purchase|
          select_post || (purchase.link.should_show_all_posts? && post.purchase_passes_filters(purchase) && post.targeted_at_purchased_item?(purchase) && post.passes_member_cancellation_checks?(purchase))
        end
      end
    end

    installments_with_sent_emails = Installment.product_or_variant_with_sent_emails_for_purchases(purchase_ids)
    profile_only_product_posts = Installment.profile_only_for_products(product_ids)
    profile_only_variant_posts = Installment.profile_only_for_variants(variant_ids)
    purchase_ids_with_same_email = Purchase.where(email: purchases.pluck(:email), seller_id: purchases.pluck(:seller_id))
                                           .all_success_states
                                           .not_fully_refunded
                                           .not_chargedback_or_chargedback_reversed
                                           .pluck(:id)
    emailed_seller_posts = Installment.seller_with_sent_emails_for_purchases(purchase_ids + purchase_ids_with_same_email)
                                      .select("installments.*, email_infos.sent_at, email_infos.delivered_at, email_infos.opened_at")
    seller_profile_posts = Installment.profile_only_for_sellers(seller_ids)
    seller_posts = check_filters.call(emailed_seller_posts + seller_profile_posts)

    profile_seller_sent_email_posts = installments_with_sent_emails + profile_only_product_posts + profile_only_variant_posts + seller_posts
    should_show_all_posts = purchases.map(&:link).any? { |product| product.should_show_all_posts? }
    if should_show_all_posts
      already_fetched_post_ids = profile_seller_sent_email_posts.map(&:id)
      past_product_posts = Installment.past_posts_to_show_for_products(product_ids:, excluded_post_ids: already_fetched_post_ids)
      past_variant_posts = Installment.past_posts_to_show_for_variants(variant_ids:, excluded_post_ids: already_fetched_post_ids)
      all_past_seller_posts = Installment.seller_posts_for_sellers(seller_ids:, excluded_post_ids: already_fetched_post_ids)
      past_seller_posts = check_filters_for_past_posts.call(all_past_seller_posts)
      past_product_or_variant_posts = check_filters_for_past_posts.call(past_product_posts + past_variant_posts)
      past_posts_to_share = past_product_or_variant_posts + past_seller_posts

      past_posts_to_share.map { |p| p.send_emails = false } # hack to get around the `i.send_emails?` check below
    else
      past_posts_to_share = []
    end

    (profile_seller_sent_email_posts + past_posts_to_share).sort_by do |i|
      i.send_emails? ? i.sent_at || i.delivered_at || i.opened_at || Time.zone.parse("1970-01-01") : i.published_at
    end.reverse
  end

  def gumroad_responsible_for_tax?
    gumroad_tax_cents.present? && gumroad_tax_cents > 0
  end

  def seller_responsible_for_tax?
    !gumroad_responsible_for_tax? && tax_cents > 0
  end

  # Public: Returns the merchant account that should be used for Affiliate
  # balances for this Purchase. Affiliate funds are always held by Gumroad,
  # and so they are always the Gumroad merchant account for the same charge
  # processor of the creators merchant account.
  def affiliate_merchant_account
    MerchantAccount.gumroad(charge_processor_id)
  end

  def attach_to_user_and_card(user, chargeable, card_data_handling_mode)
    self.purchaser = user

    if chargeable.present? && successful? && chargeable.fingerprint == stripe_fingerprint
      card = CreditCard.create(chargeable, card_data_handling_mode, user)
      if card.errors.empty?
        card.users << user
        self.credit_card = card
        self.session_id = nil
      end
    end

    if preorder.present?
      preorder.purchaser = user
      preorder.save!
    end

    if subscription.present? && !is_gift_sender_purchase
      subscription.user = user
      subscription.save!
    end

    begin
      save!
    rescue ActiveRecord::RecordInvalid => e
      logger.info("Attaching user to purchase #{id}: Could save purchase after attaching user #{user.id}. Exception: #{e.message}")
    end
  end

  def seller_balance_update_eligible?
    (purchase_chargeback_balance.nil? || chargeback_reversed) && (purchase_refund_balance.nil? || stripe_partially_refunded || stripe_partially_refunded_was)
  end

  def upload_invoice_pdf(pdf)
    timestamp = Time.current.strftime("%F")
    key = "#{Rails.env}/#{timestamp}/invoices/purchases/#{external_id}-#{SecureRandom.hex}/invoice.pdf"

    s3_obj = Aws::S3::Resource.new.bucket(INVOICES_S3_BUCKET).object(key)
    s3_obj.put(body: pdf)
    s3_obj
  end

  # Unsubscribe the buyer of this purchase from all of the seller's emails
  def unsubscribe_buyer
    Purchase.where(email:, seller_id:, can_contact: true).find_each do |purchase|
      purchase.update!(can_contact: false)
    rescue ActiveRecord::RecordInvalid
      Rails.logger.info "Could not update purchase (#{id}) with validations turned on. Unsubscribing the buyer without running validations."

      purchase.can_contact = false
      purchase.save(validate: false)
    end

    Follower.unsubscribe(seller_id, email)
  end

  def send_notification_webhook_from_ui
    # for gifts, only send a webhook for the giftee's purchase, not for the
    # gifter's purchase
    if is_gift_sender_purchase
      giftee_purchase = gift.giftee_purchase
      giftee_purchase.send_notification_webhook if giftee_purchase
    else
      send_notification_webhook
    end
  end

  def send_notification_webhook
    return if is_gift_sender_purchase

    after_commit do
      next if destroyed?
      PostToPingEndpointsWorker.perform_in(10.seconds, id, url_parameters)
    end
  end

  def sync_status_with_charge_processor(mark_as_failed: false)
    Purchase::SyncStatusWithChargeProcessorService.new(self, mark_as_failed:).perform
  end

  def formatted_error_code
    fallback_code = stripe_error_code || error_code
    formatted_error_message || fallback_code.to_s.tr("_", " ").titleize
  end

  def formatted_error_message
    if charge_processor_id == StripeChargeProcessor.charge_processor_id
      PurchaseErrorCode::STRIPE_ERROR_CODES.find { |err_code, _err_msg| stripe_error_code.to_s.include?(err_code) }&.last
    else
      PurchaseErrorCode::PAYPAL_ERROR_CODES[stripe_error_code.to_s]
    end
  end

  # schedule workflows for the purchase's variant(s), optionally excluding workflows
  # that would have been scheduled for the excluded variants. (Useful when updating
  # a subscription's tier in order to avoid re-scheduling workflows that should
  # already be scheduled before the tier change, for example.)
  def schedule_workflows_for_variants(excluded_variants: [])
    return if excluded_variants.sort == variant_attributes.sort

    excluded_workflows = excluded_variants.map do |variant|
      seller.workflows.filter { |workflow| workflow.targets_variant?(variant) }
    end.flatten

    to_schedule = variant_attributes.map do |variant|
      seller.workflows.alive.filter { |workflow| !excluded_workflows.include?(workflow) && workflow.targets_variant?(variant) }
    end.flatten

    schedule_workflows(to_schedule)
  end

  def schedule_workflows(workflows)
    workflows.each do |workflow|
      next if workflow.abandoned_cart_type?
      next unless workflow.new_customer_trigger?
      next unless workflow.applies_to_purchase?(self)

      workflow.installments.alive.published.each do |installment|
        installment_rule = installment.installment_rule
        next if installment_rule.nil?

        SendWorkflowInstallmentWorker.perform_at(created_at + installment_rule.delayed_delivery_time,
                                                 installment.id, installment_rule.version, id, nil, nil)
      end
    end
  end

  def reschedule_workflow_installments(send_delay: nil)
    return unless send_delay.present? && send_delay > 1.minute # ignore quick unsubscribes + resubscribes

    all_workflows.each do |workflow|
      next unless workflow.applies_to_purchase?(self)

      active_workflow_installments = workflow.installments.includes(:installment_rule).alive.published
      has_any_past_workflow_installments = active_workflow_installments.any? do |installment|
        installment.installment_rule.present? && (original_purchase.created_at + installment.installment_rule.delayed_delivery_time < Time.current)
      end

      next unless has_any_past_workflow_installments

      active_workflow_installments.each do |installment|
        installment_rule = installment.installment_rule
        next unless installment_rule.present?
        deliver_at = original_purchase.created_at + send_delay + installment_rule.delayed_delivery_time
        after_commit do
          next if destroyed?
          SendWorkflowInstallmentWorker.perform_at(deliver_at, installment.id, installment_rule.version, id, nil)
        end
      end
    end
  end

  def schedule_all_workflows
    schedule_workflows(all_workflows)
  end

  def customizable_price?
    (link.is_tiered_membership && tier.present? ? tier.customizable_price? : link.customizable_price?) || (seller.tipping_enabled? && tip.present?)
  end

  def has_payment_error?
    purchase_state == "failed" || stripe_error_code.present? || (error_code.present? && PurchaseErrorCode::PAYMENT_ERROR_CODES.include?(error_code))
  end

  def has_retryable_payment_error?
    PurchaseErrorCode.is_error_retryable?(error_code) ||
      PurchaseErrorCode.is_error_retryable?(stripe_error_code)
  end

  def has_payment_network_error?
    PurchaseErrorCode.is_temporary_network_error?(error_code) ||
      PurchaseErrorCode.is_temporary_network_error?(stripe_error_code)
  end

  def statement_description
    link.user.name_or_username || "Gumroad"
  end

  def tiers
    return [] unless link.is_tiered_membership?
    variant_attributes.present? ? variant_attributes : [link.default_tier]
  end

  def tier
    variant_attributes.first if link.is_tiered_membership?
  end

  def purchaser_card_supported?
    purchaser.present? && purchaser.credit_card.present? &&
        (purchaser.credit_card.charge_processor_id != PaypalChargeProcessor.charge_processor_id ||
            seller.native_paypal_payment_enabled?)
  end

  def original_purchase
    subscription_id.present? ? subscription.original_purchase : self
  end

  def true_original_purchase
    subscription_id.present? ? subscription.true_original_purchase : self
  end

  def paypal_fee_usd_cents
    return 0 if charge_processor_id != PaypalChargeProcessor.charge_processor_id ||
      processor_fee_cents_currency.blank? ||
      processor_fee_cents.to_i == 0
    get_usd_cents(processor_fee_cents_currency, processor_fee_cents)
  end

  def total_fee_cents
    fee_cents + paypal_fee_usd_cents
  end

  # "not_charged" purchases that are free trial purchases should be treated as
  # successful purchases for the purposes of some tasks such as scheduling workflows,
  # while other "not_charged" purchases should not be. This method identifies
  # "not_charged" purchases that should be excluded in these cases (e.g. updated
  # subscription purchases).
  def not_charged_and_not_free_trial?
    not_charged? && !is_free_trial_purchase?
  end

  def country_or_from_ip_address
    country.nil? ? geo_info.try(:country_name) : country
  end

  def state_or_from_ip_address
    state.nil? ? geo_info.try(:region_name) : state
  end

  def country_or_ip_country
    country.presence || ip_country
  end

  def displayed_price_cents_before_offer_code(include_deleted: false)
    offer_code_to_use = original_offer_code(include_deleted:)
    return displayed_price_cents unless offer_code_to_use.present?

    price = has_cached_offer_code? ?
      purchase_offer_code_discount.pre_discount_minimum_price_cents :
      offer_code_to_use.original_price(displayed_price_cents)
    price * quantity if price.present?
  end

  def displayed_price_per_unit_cents
    displayed_price_cents / quantity
  end

  def original_offer_code(include_deleted: false)
    return nil if offer_code&.deleted? && !include_deleted

    if has_cached_offer_code?
      code = purchase_offer_code_discount.offer_code.code
      purchase_offer_code_discount.offer_code_is_percent ?
        OfferCode.new(amount_percentage: purchase_offer_code_discount.offer_code_amount, code:) :
        OfferCode.new(amount_cents: purchase_offer_code_discount.offer_code_amount, code:)
    else
      offer_code
    end
  end

  def discover_fee_per_thousand
    recommended_purchase_info&.discover_fee_per_thousand || GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND
  end

  def is_direct_to_australian_customer?
    link.is_physical? && country == Compliance::Countries::AUS.common_name
  end

  def enqueue_update_sales_related_products_infos_job(increment = true)
    UpdateSalesRelatedProductsInfosJob.perform_async(id, increment)
  end

  def free_purchase?
    price_cents == 0 && shipping_cents == 0
  end

  def display_referrer
    if recommended_by == RecommendationType::GUMROAD_LIBRARY_RECOMMENDATION
      "Gumroad Library"
    elsif was_product_recommended || was_discover_fee_charged
      case recommended_by
      when RecommendationType::GUMROAD_RECEIPT_RECOMMENDATION
        "Gumroad Receipt"
      when RecommendationType::GUMROAD_LIBRARY_RECOMMENDATION
        "Gumroad Library"
      when RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION
        "Gumroad Product Recommendations"
      when RecommendationType::PRODUCT_RECOMMENDATION
        "Gumroad Product Page"
      when RecommendationType::WISHLIST_RECOMMENDATION
        "Gumroad Wishlist"
      else
        "Gumroad Discover"
      end
    elsif referrer == "direct"
      "Direct"
    elsif referrer.present?
      referrer_domain = Referrer.extract_domain(referrer)
      if referrer_domain.start_with?("#{seller.username}.gumroad.")
        "Profile"
      else
        COMMON_REFERRERS_NAMES[referrer_domain] || referrer_domain
      end
    end
  end

  def ppp_info
    if is_purchasing_power_parity_discounted && purchasing_power_parity_info.present?
      { country: ip_country, discount: "#{((1 - purchasing_power_parity_info.factor) * 100).round}%" }
    end
  end

  def save_charge_data(processor_charge, chargeable: nil)
    self.charge_processor_id = processor_charge.charge_processor_id
    self.stripe_refunded = processor_charge.refunded
    self.stripe_transaction_id = processor_charge.id
    self.processor_fee_cents = processor_charge.fee
    self.processor_fee_cents_currency = processor_charge.fee_currency
    self.stripe_fingerprint = chargeable&.fingerprint || processor_charge.card_fingerprint
    self.stripe_card_id = processor_charge.card_instance_id
    self.card_expiry_month = processor_charge.card_expiry_month
    self.card_expiry_year = processor_charge.card_expiry_year
    self.was_zipcode_check_performed = !processor_charge.zip_check_result.nil?
    save!

    charge.update_charge_details_from_processor!(processor_charge) if charge.present?
    load_flow_of_funds(processor_charge)
  end

  def is_an_off_session_charge_on_indian_card?
    charge_processor_id == StripeChargeProcessor.charge_processor_id && card_country == "IN" && (preorder.present? || is_recurring_subscription_charge)
  end

  # Off-session charges on Indian cards remain in processing for 26 hours on Stripe.
  # We keep the purchase in_progress for that duration, so avoid forced updates (from admin or background jobs).
  def can_force_update?
    in_progress? && (!is_an_off_session_charge_on_indian_card? || created_at < 26.hours.ago)
  end

  def linked_license
    if license_key.present?
      license
    elsif is_gift_sender_purchase && gift.giftee_purchase.present? && gift.giftee_purchase.license_key.present?
      gift.giftee_purchase.license
    end
  end

  def load_and_prepare_chargeable(credit_card)
    chargeable = load_chargeable_for_charging
    return chargeable if errors.present?

    validate_chargeable_for_charging(chargeable)
    return chargeable if errors.present?

    if credit_card.present?
      self.credit_card = credit_card
      if credit_card.errors.present?
        self.stripe_error_code = credit_card.stripe_error_code
        self.error_code = credit_card.error_code
        self.errors.add :base, credit_card.errors.messages[:base].first
      end
    end

    prepare_chargeable_for_charge!(chargeable)
  end

  def mandate_options_for_stripe(with_currency: false)
    return unless chargeable&.requires_mandate?
    # We only need to create a mandate if off session charges are required later i.e.
    # either this is a membership purchase or a preorder authorisation purchase.
    return unless is_original_subscription_purchase? || is_preorder_authorization? || is_upgrade_purchase? || setup_future_charges
    # For carts with multiple products, we've already created a setup intent
    # before initiating the checkout and associated a mandate with it
    # Ref: Stripe::SetupIntentsController#create
    return if is_multi_buy?

    interval = "sporadic"
    interval_count = 1

    if is_original_subscription_purchase? || is_upgrade_purchase?
      case subscription_duration
      when "every_two_years"
        interval = "year"
        interval_count = 2
      when "yearly"
        interval = "year"
        interval_count = 1
      when "monthly"
        interval = "month"
        interval_count = 1
      when "quarterly"
        interval = "month"
        interval_count = 3
      when "biannually"
        interval = "month"
        interval_count = 6
      end
    end

    mandate_options = {
      payment_method_options: {
        card: {
          mandate_options: {
            reference: StripeChargeProcessor::MANDATE_PREFIX + (Rails.env.production? ? external_id : SecureRandom.hex),
            amount_type: "maximum",
            amount: is_upgrade_purchase? ? subscription.original_purchase.total_transaction_cents : total_transaction_cents,
            start_date: Time.current.to_i,
            interval:,
            interval_count:,
            supported_types: ["india"]
          }
        }
      }
    }
    mandate_options[:payment_method_options][:card][:mandate_options][:currency] = "usd" if with_currency
    mandate_options
  end

  def name_or_email
    full_name.presence || email
  end

  def build_flow_of_funds_from_combined_charge(combined_flow_of_funds)
    total_issued_amount_cents = combined_flow_of_funds.issued_amount.cents
    purchase_portion = total_transaction_cents * 1.0 / charge.amount_cents
    purchase_gumroad_amount_portion = if charge.gumroad_amount_cents == 0
      0
    else
      total_transaction_amount_for_gumroad_cents * 1.0 / charge.gumroad_amount_cents
    end
    purchase_seller_portion = (total_transaction_cents - total_transaction_amount_for_gumroad_cents) * 1.0 /
        (charge.amount_cents - charge.gumroad_amount_cents)

    issued_amount_cents = (total_issued_amount_cents * purchase_portion).floor
    settled_amount_cents = (combined_flow_of_funds.settled_amount.cents * purchase_portion).floor
    gumroad_amount_cents = (combined_flow_of_funds.gumroad_amount.cents * purchase_gumroad_amount_portion).floor

    issued_amount = FlowOfFunds::Amount.new(currency: combined_flow_of_funds.issued_amount.currency, cents: issued_amount_cents)
    settled_amount = FlowOfFunds::Amount.new(currency: combined_flow_of_funds.settled_amount.currency, cents: settled_amount_cents)
    gumroad_amount = FlowOfFunds::Amount.new(currency: combined_flow_of_funds.gumroad_amount.currency, cents: gumroad_amount_cents)

    if combined_flow_of_funds.merchant_account_gross_amount.present?
      merchant_account_gross_amount_cents = (combined_flow_of_funds.merchant_account_gross_amount.cents * purchase_seller_portion).floor
      merchant_account_gross_amount = FlowOfFunds::Amount.new(currency: combined_flow_of_funds.merchant_account_gross_amount.currency,
                                                              cents: merchant_account_gross_amount_cents)
      merchant_account_net_amount_cents = (combined_flow_of_funds.merchant_account_net_amount.cents * purchase_seller_portion).floor
      merchant_account_net_amount = FlowOfFunds::Amount.new(currency: combined_flow_of_funds.merchant_account_net_amount.currency,
                                                            cents: merchant_account_net_amount_cents)
    end

    FlowOfFunds.new(issued_amount:, settled_amount:, gumroad_amount:, merchant_account_gross_amount:, merchant_account_net_amount:)
  end

  def eligible_for_review_reminder?
    purchase_state.in?(Purchase::COUNTS_REVIEWS_STATES) &&
    (is_original_subscription_purchase? || link.not_is_recurring_billing?) &&
      not_is_bundle_purchase? &&
      product_review.blank? &&
      !chargedback_not_reversed_or_refunded? &&
      (purchaser.present? ? !purchaser.opted_out_of_review_reminders? : true)
  end

  def check_for_blocked_customer_emails
    blocked_email = blockable_emails_if_fraudulent_transaction.find do |email|
      BlockedCustomerObject.email_blocked?(email:, seller_id:)
    end

    return if blocked_email.blank?

    self.error_code = PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS
    errors.add :base, "Your card was not charged, as the creator has prevented you from purchasing this item. Please contact them for more information."
  end

  def validate_purchasing_power_parity
    return if !is_purchasing_power_parity_discounted || seller.purchasing_power_parity_payment_verification_disabled?
    if card_country != Compliance::Countries.find_by_name(ip_country)&.alpha2
      errors.add :base, "In order to apply a purchasing power parity discount, you must use a card issued in the country you are in. Please try again with a local card, or remove the discount during checkout."
      self.error_code = PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING
    end
  end

  private
    def offer_amount_off(purchase_min_price)
      # For commissions, apply deposit purchase's offer code to its completion
      # purchase even if it has been soft deleted.
      original_offer_code(include_deleted: is_commission_completion_purchase?)
        &.amount_off(purchase_min_price) || 0
    end

    def displayed_price_usd_cents
      get_usd_cents(displayed_price_currency_type, displayed_price_cents)
    end

    def transcode_product_videos
      # Transcode videos immediately after successful purchase
      link.transcode_videos!(queue: "critical")

      # Videos uploaded in the future would be automatically transcoded since the product would contain at least one
      # successful purchase. We can disable transcode on purchase to avoid unnecessary transcode attempts.
      link.transcode_videos_on_purchase = false
      link.save!
    end

    def process_without_charging!
      set_price_and_rate
      calculate_fees
      save

      return if is_gift_receiver_purchase

      create_sales_tax_info!
      return if errors.present?

      calculate_shipping
      save

      if free_purchase?
        check_for_blocked_customer_emails
        return
      end

      should_prepare_for_charge = !is_test_purchase? && !skip_preparing_for_charge
      if should_prepare_for_charge
        unless is_part_of_combined_charge?
          chargeable = load_chargeable_for_charging
          return if errors.present?

          validate_chargeable_for_charging(chargeable)
          return if errors.present?

          chargeable = prepare_chargeable_for_charge!(chargeable)
          return if errors.present?
        end
      end

      purchase_sales_tax_info.card_country_code = card_country if is_part_of_combined_charge?
      calculate_taxes
      return if errors.present?

      self.price_cents += tax_cents if was_tax_excluded_from_price
      self.total_transaction_cents = self.price_cents + gumroad_tax_cents

      # Actually add the shipping amount to price cents and update total transaction cents
      self.price_cents += shipping_cents
      self.total_transaction_cents += shipping_cents

      calculate_fees

      validate_seller_revenue
      return if errors.present?

      purchase_sales_tax_info.save
      save

      return unless should_prepare_for_charge

      unless is_part_of_combined_charge?
        validate_purchasing_power_parity
        return if errors.present?

        if is_preorder_authorization || is_free_trial_purchase?
          create_setup_intent(chargeable) if setup_future_charges
          return
        end

        check_for_blocked_customer_emails
        return if errors.present?
      end

      chargeable
    end

    def load_flow_of_funds(processor_charge)
      processor_charge.flow_of_funds ||= FlowOfFunds.build_simple_flow_of_funds(Currency::USD, self.total_transaction_cents) if StripeChargeProcessor.charge_processor_id != charge_processor_id
      self.flow_of_funds = if is_part_of_combined_charge?
        build_flow_of_funds_from_combined_charge(processor_charge.flow_of_funds)
      else
        processor_charge.flow_of_funds
      end
    end

    def additional_fields_for_creator_app_api
      alert_string = if self.price_cents == 0 && !link.is_physical
        "New download of #{link.name}"
      else
        "New sale of #{link.name} for #{formatted_total_price}"
      end

      {
        alert: alert_string,
        product_thumbnail_url: link.thumbnail&.alive&.url.presence,
        formatted_total_price:,
        refunded: stripe_refunded?,
        partially_refunded: stripe_partially_refunded,
        chargedback: chargedback_not_reversed?,
      }
    end

    def determine_affiliate_balance_cents
      return 0 if affiliate.nil?

      affiliate_cents = affiliate_cut * displayed_price_usd_cents
      affiliate_cents -= determine_affiliate_fee_cents
      affiliate_cents.floor
    end

    def affiliate_cut
      affiliate.basis_points(product_id: link_id) / 10_000.0
    end

    def determine_affiliate_fee_cents
      return 0 if fee_cents.blank? || (!affiliate.collaborator? && (seller.bears_affiliate_fee? || Feature.active?(:sellers_bear_affiliate_fees)))
      affiliate_cut * fee_cents
    end

    # Private: truncate the referrer so that they fit in our mysql string column.
    def truncate_referrer
      self.referrer = referrer.first(191) if referrer
    end

    def validate_seller_revenue
      return unless price_cents
      return if price_cents == 0
      return if price_cents > fee_cents + affiliate_credit_cents

      self.error_code = PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE
      errors.add(:base, "Your purchase failed because the product is not correctly set up. Please contact the creator for more information.")
    end

    # Private: Prepare for charging the chargeable and retrieve any information about the chargeable that's needed
    # for risk analysis prior to charge. Will also return a chargeable that may be the same object or a new object.
    # If a new chargeable is to be converted into a CreditCard for later use by a user, or for a preorder or subscription
    # then the given chargeable will be used to persist a credit card and then a new chargeable will be created from that
    # credit card. The new chargeable will be returned.
    #
    # Returns: The final chargeable that should be used for charging. May be the same object passed in or different.
    def prepare_chargeable_for_charge!(chargeable)
      begin
        self.card_visual = chargeable.visual
        self.card_expiry_month = chargeable.expiry_month if chargeable.expiry_month.present?
        self.card_expiry_year = chargeable.expiry_year if chargeable.expiry_year.present?

        if credit_card.nil? && save_chargeable?
          self.setup_future_charges = true
          self.credit_card = CreditCard.create(chargeable, card_data_handling_mode, purchaser)

          if credit_card.errors.present?
            self.stripe_error_code = credit_card.stripe_error_code
            self.error_code = credit_card.error_code
            errors.add :base, credit_card.errors.messages[:base].first
            return
          end

          credit_card.users << purchaser if purchaser.present?
        end

        # Attach shipping address to the purchaser if option is selected.
        if save_shipping_address && purchaser.present? && street_address.present?
          purchaser.update!(
            street_address:,
            city:,
            state:,
            zip_code:,
            country:
          )
        end

        # The chargeable will be prepared and information within the chargeable may be updated or now be available.
        # The chargeable may also contact a charge processor so this call may not be fast and if the call fails or
        # the chargeable is declined by the processor (indicated by the false value) we'll stop the purchase here.
        chargeable.prepare!

        # after the chargeable is prepared, all information about it is updated into the purchase
        self.charge_processor_id = chargeable.charge_processor_id
        self.stripe_fingerprint = chargeable.fingerprint
        self.card_type = chargeable.card_type
        self.card_country = chargeable.country
        purchase_sales_tax_info.card_country_code = chargeable.country
        self.credit_card_zipcode = chargeable.zip_code
        self.card_visual = chargeable.visual
        self.card_expiry_month = chargeable.expiry_month
        self.card_expiry_year = chargeable.expiry_year
      rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
        logger.error "Error while preparing chargeable: #{e.message} in purchase: #{external_id}"
        errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
        self.error_code = charge_processor_unavailable_error
      rescue ChargeProcessorCardError => e
        self.stripe_error_code = e.error_code
        logger.info "Error while preparing chargeable: #{e.message} in purchase: #{external_id}"
        errors.add :base, PurchaseErrorCode.customer_error_message(e.message)
      end

      chargeable
    end

    def save_chargeable?
      (purchaser.present? && save_card && chargeable&.can_be_saved?) ||
        is_preorder_authorization? ||
        link.is_recurring_billing? ||
        link.native_type == Link::NATIVE_TYPE_COMMISSION ||
        is_installment_payment
    end

    def charge_processor_unavailable_error
      if charge_processor_id.blank? || charge_processor_id == StripeChargeProcessor.charge_processor_id
        PurchaseErrorCode::STRIPE_UNAVAILABLE
      else
        PurchaseErrorCode::PAYPAL_UNAVAILABLE
      end
    end

    def prepare_merchant_account(charge_processor_id)
      # Note: This assumes for the time being that all chargeables have only one internal chargeable.
      self.merchant_account = seller.merchant_account(charge_processor_id)
      self.merchant_account ||= MerchantAccount.gumroad(charge_processor_id)
      if merchant_account&.is_a_brazilian_stripe_connect_account? && affiliate.present?
        self.error_code = PurchaseErrorCode::BRAZILIAN_MERCHANT_ACCOUNT_WITH_AFFILIATE
        errors.add(:base, "Affiliate sales are not currently supported for this product.")
      end
      calculate_fees
    end

    def create_setup_intent(chargeable)
      with_charge_processor_error_handler do
        self.setup_intent = ChargeProcessor.setup_future_charges!(self.merchant_account, chargeable,
                                                                  mandate_options: mandate_options_for_stripe(with_currency: true))
        return unless setup_intent.present?

        self.processor_setup_intent_id = setup_intent.id
        credit_card.update!(json_data: { stripe_setup_intent_id: setup_intent.id }) if credit_card&.requires_mandate?
        save!

        unless setup_intent.succeeded? || setup_intent.requires_action?
          errors.add :base, "Sorry, something went wrong."
        end
      end
    end

    def create_charge_intent(chargeable, off_session: true)
      with_charge_processor_error_handler do
        amount_cents = total_transaction_cents
        amount_for_gumroad_cents = total_transaction_amount_for_gumroad_cents
        description = "You bought #{link.long_url}!"
        mandate_options = mandate_options_for_stripe

        charge_intent = ChargeProcessor.create_payment_intent_or_charge!(self.merchant_account,
                                                                         chargeable,
                                                                         amount_cents,
                                                                         amount_for_gumroad_cents,
                                                                         external_id,
                                                                         description,
                                                                         statement_description:,
                                                                         transfer_group: id,
                                                                         off_session:,
                                                                         setup_future_charges:,
                                                                         mandate_options:)

        if charge_intent.id.present?
          if processor_payment_intent.present?
            processor_payment_intent.update!(intent_id: charge_intent.id)
          else
            create_processor_payment_intent!(intent_id: charge_intent.id)
          end
        end
        save!
        credit_card.update!(json_data: { stripe_payment_intent_id: charge_intent.id }) if credit_card&.requires_mandate? && mandate_options.present?

        charge_intent
      end
    end

    def with_charge_processor_error_handler
      yield
    rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
      logger.error "Charge processor error: #{e.message} in purchase: #{external_id}"
      errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      self.error_code = charge_processor_unavailable_error
      nil
    rescue ChargeProcessorPayeeAccountRestrictedError => e
      logger.error "Charge processor error: #{e.message} in purchase: #{external_id}"
      errors.add :base, "There is a problem with creator's paypal account, please try again later (your card was not charged)."
      self.stripe_error_code = PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED
      nil
    rescue ChargeProcessorPayerCancelledBillingAgreementError => e
      logger.error "Error while creating charge: #{e.message} in purchase: #{external_id}"
      errors.add :base, "Customer has cancelled the billing agreement on PayPal."
      self.stripe_error_code = PurchaseErrorCode::PAYPAL_PAYER_CANCELLED_BILLING_AGREEMENT
      nil
    rescue ChargeProcessorPaymentDeclinedByPayerAccountError => e
      logger.error "Error while creating charge: #{e.message} in purchase: #{external_id}"
      errors.add :base, "Customer PayPal account has declined the payment."
      self.stripe_error_code = PurchaseErrorCode::PAYPAL_PAYER_ACCOUNT_DECLINED_PAYMENT
      nil
    rescue ChargeProcessorUnsupportedPaymentTypeError => e
      logger.info "Charge processor error: Unsupported paypal payment method selected"
      errors.add :base, "We weren't able to charge your PayPal account. Please select another method of payment."
      self.stripe_error_code = e.error_code
      self.stripe_transaction_id = e.charge_id
      nil
    rescue ChargeProcessorUnsupportedPaymentAccountError => e
      logger.info "Charge processor error: PayPal account used is not supported"
      errors.add :base, "Your PayPal account cannot be charged. Please select another method of payment."
      self.stripe_error_code = e.error_code
      self.stripe_transaction_id = e.charge_id
      nil
    rescue ChargeProcessorCardError => e
      self.stripe_error_code = e.error_code
      self.stripe_transaction_id = e.charge_id
      self.was_zipcode_check_performed = true if e.error_code == "incorrect_zip"
      logger.info "Charge processor error: #{e.message} in purchase: #{external_id}"
      errors.add :base, PurchaseErrorCode.customer_error_message(e.message)
      nil
    rescue ChargeProcessorErrorRateLimit => e
      logger.error "Charge processor error: #{e.message} in purchase: #{external_id}"
      errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      self.error_code = charge_processor_unavailable_error
      raise e
    rescue ChargeProcessorErrorGeneric => e
      logger.error "Charge processor error: #{e.message} in purchase: #{external_id}"
      errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
      self.stripe_error_code = e.error_code
      nil
    end

    # Private: Returns true if a custom file receipt should be sent for this
    # purchase, false otherwise.
    #
    # if it's a gift sender purchase, then there's no url_redirect for this
    # purchase and we should just send a normal receipt without a link.
    def needs_custom_file_receipt
      link.customize_file_per_purchase? && !is_gift_sender_purchase
    end

    # Private: Loads the chargeable object that should be used for charging this purchase. This may be the chargeable
    # object created when an external party created the purchase (self.chargeable) or it may created here
    # if the purchase is being made on a logged in user's (self.purchaser) credit card or a credit card has been
    # predefined (e.g. in the preorder flow this happens).
    # In case the purchase is a subscription it should charge the subscription.credit_card, in case it is present
    #
    # If a card parameter error has been give to the purchase, it will be handled here during the loading process since
    # no card data has been provided and the error is the explanation for why that is the case.
    #
    # Returns: The final chargeable that should be used for charging. May be the same object passed in or different.
    # If there is no chargeable available nil will be returned.
    def load_chargeable_for_charging
      if card_data_handling_error.present?
        logger.error %(Card params error in purchase: #{external_id} -
                       #{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code})
        if card_data_handling_error.is_card_error?
          self.stripe_error_code = card_data_handling_error.card_error_code
          errors.add :base, PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message)
        else
          self.error_code = charge_processor_unavailable_error
          errors.add :base, "There is a temporary problem, please try again (your card was not charged)."
        end
        return nil
      end

      if chargeable.present?
        prepare_merchant_account(chargeable.charge_processor_id)
        return chargeable
      elsif subscription.present? && subscription.credit_card.present?
        self.credit_card = subscription.credit_card
      elsif purchaser_card_supported?
        self.credit_card = purchaser.credit_card
      end

      if credit_card.present?
        # set the card data handling mode to nothing since we're not handling card data if we're using a pre-existing saved card
        self.card_data_handling_mode = nil
        self.charge_processor_id ||= credit_card.charge_processor_id
        prepare_merchant_account(credit_card.charge_processor_id)
        return credit_card.to_chargeable(merchant_account:)
      end

      logger.error "No credit card information provided in purchase: #{external_id}."
      self.error_code = PurchaseErrorCode::CREDIT_CARD_NOT_PROVIDED
      errors.add :base, PurchaseErrorCode.customer_error_message
      nil
    end

    def validate_chargeable_for_charging(chargeable)
      raise "A chargeable backed by multiple charge processors was provided in purchase: #{external_id}." if chargeable.charge_processor_ids.length != 1
    end

    def price_not_too_high
      max_product_price = link.user.max_product_price
      return if self.price_cents.nil? || max_product_price.nil?
      return if self.price_cents <= max_product_price

      self.error_code = PurchaseErrorCode::PRICE_TOO_HIGH
      errors.add(:base, "Sorry, we limit purchases to $5,000 at the moment.")
    end

    def price_not_too_low
      return if errors.present?
      return if is_bundle_product_purchase?

      min_price = link.currency["min_price"]
      formatted_min_price = formatted_price(link.price_currency_type, min_price)

      # normal purchases of customizable_price products cannot be less than minimum for currency, unless they're 0.
      if customizable_price? && displayed_price_cents < min_price && self.price_cents != 0
        self.error_code = PurchaseErrorCode::CONTRIBUTION_TOO_LOW
        errors.add(:base, "The amount must be at least #{formatted_min_price}.")
        return
      end

      return if displayed_price_cents >= minimum_paid_price_cents

      self.error_code = PurchaseErrorCode::PRICE_CENTS_TOO_LOW
      errors.add(:base, "Please enter an amount greater than or equal to the minimum.")
    end

    # Private: validator that guarantees that the right transaction information is present for paid purchases.
    def financial_transaction_validation
      return if self.price_cents > 0 &&
                stripe_transaction_id.present? &&
                merchant_account.present? &&
                (stripe_fingerprint.present? || paypal_order_id) &&
                charge_processor_id.present?

      return if (self.price_cents == 0 || self.price_cents.nil?) &&
                stripe_transaction_id.blank? &&
                stripe_fingerprint.blank? &&
                charge_processor_id.nil? &&
                self.merchant_account.nil?

      errors.add(:base, "We couldn't charge your card. Try again or use a different card.")
    end

    def zip_code_from_geoip
      self.zip_code ||= geo_info.try(:postal_code)
    end

    def create_sales_tax_info!
      return if purchase_sales_tax_info

      purchase_sales_tax_info = PurchaseSalesTaxInfo.new
      purchase_sales_tax_info.ip_address = ip_address
      purchase_sales_tax_info.postal_code = zip_code
      purchase_sales_tax_info.state_code = state

      purchase_sales_tax_info.country_code = Compliance::Countries.find_by_name(country)&.alpha2
      purchase_sales_tax_info.ip_country_code = Compliance::Countries.find_by_name(ip_country)&.alpha2
      purchase_sales_tax_info.elected_country_code = sales_tax_country_code_election

      if business_vat_id
        if Compliance::Countries::AUS.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if AbnValidationService.new(business_vat_id).process
        elsif Compliance::Countries::SGP.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if GstValidationService.new(business_vat_id).process
        elsif Compliance::Countries::CAN.alpha2 == purchase_sales_tax_info.country_code &&
              QUEBEC == purchase_sales_tax_info.state_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if QstValidationService.new(business_vat_id).process
        elsif Compliance::Countries::NOR.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if MvaValidationService.new(business_vat_id).process
        elsif Compliance::Countries::BHR.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if TrnValidationService.new(business_vat_id).process
        elsif Compliance::Countries::KEN.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if KraPinValidationService.new(business_vat_id).process
        elsif Compliance::Countries::OMN.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if OmanVatNumberValidationService.new(business_vat_id).process
        elsif Compliance::Countries::NGA.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if FirsTinValidationService.new(business_vat_id).process
        elsif Compliance::Countries::TZA.alpha2 == purchase_sales_tax_info.country_code
          purchase_sales_tax_info.business_vat_id = business_vat_id if TraTinValidationService.new(business_vat_id).process
        elsif Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.include?(purchase_sales_tax_info.country_code) ||
              Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS_WITH_TAX_ID_PRO_VALIDATION.include?(purchase_sales_tax_info.country_code)
          purchase_sales_tax_info.business_vat_id = business_vat_id if TaxIdValidationService.new(business_vat_id, purchase_sales_tax_info.country_code).process
        else
          purchase_sales_tax_info.business_vat_id = business_vat_id if VatValidationService.new(business_vat_id).process
        end
      end

      self.purchase_sales_tax_info = purchase_sales_tax_info
      self.purchase_sales_tax_info.save!
    end

    def charge_discover_fee?
      return false unless link.recommendable? || (not_is_original_subscription_purchase? && original_purchase&.was_discover_fee_charged?)
      was_product_recommended? && !RecommendationType.is_free_recommendation_type?(recommended_by)
    end

    # Calculates the fees we charge based on price_cents
    #
    # This is called multiple times from process!.
    # This function should only set fee_cents and not change any other state.
    def calculate_fees
      return unless self.price_cents

      if price_cents == 0 || merchant_account&.is_a_brazilian_stripe_connect_account?
        self.fee_cents = 0
        return
      end

      fee_per_thousand = calculate_gumroad_fee_per_thousand

      if charge_discover_fee?
        discover_fee_per_thousand = calculate_additional_discover_fee_per_thousand
        if discover_fee_per_thousand > 0
          fee_per_thousand += discover_fee_per_thousand
          self.was_discover_fee_charged = true
        end
      end

      variable_fee_cents = (price_cents * fee_per_thousand / 1000.0).round

      fixed_processor_fee_cents = charged_using_gumroad_merchant_account? ? PROCESSOR_FIXED_FEE_CENTS : 0
      fixed_fee_cents = if is_recurring_subscription_charge
        if subscription.mor_fee_applicable?
          was_discover_fee_charged? ? 0 : GUMROAD_FIXED_FEE_CENTS + fixed_processor_fee_cents
        else
          fixed_processor_fee_cents
        end
      else
        was_discover_fee_charged? ? 0 : GUMROAD_FIXED_FEE_CENTS + fixed_processor_fee_cents
      end

      self.fee_cents = variable_fee_cents + fixed_fee_cents
      self.affiliate_credit_cents = determine_affiliate_balance_cents
    end

    def calculate_additional_discover_fee_per_thousand
      if is_recurring_subscription_charge || is_updated_original_subscription_purchase
        subscription.original_purchase.discover_fee_per_thousand - (flat_fee_applicable? ? (custom_fee_per_thousand.presence || GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND) : 0) - (subscription.mor_fee_applicable? && charged_using_gumroad_merchant_account? ? PROCESSOR_FEE_PER_THOUSAND : 0)
      elsif is_preorder_charge?
        preorder.authorization_purchase.discover_fee_per_thousand - (flat_fee_applicable? ? (custom_fee_per_thousand.presence || GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND) + PROCESSOR_FEE_PER_THOUSAND : 0)
      else
        GUMROAD_DISCOVER_FEE_PER_THOUSAND - (custom_fee_per_thousand.presence || GUMROAD_DISCOVER_EXTRA_FEE_PER_THOUSAND) - (charged_using_gumroad_merchant_account? ? PROCESSOR_FEE_PER_THOUSAND : 0)
      end
    end

    def calculate_gumroad_fee_per_thousand
      if flat_fee_applicable?
        calculate_custom_fee_per_thousand
        (custom_fee_per_thousand.presence || gumroad_flat_fee_per_thousand) + (charged_using_gumroad_merchant_account? ? PROCESSOR_FEE_PER_THOUSAND : 0)
      elsif seller.tier_pricing_enabled?
        (seller.tier_fee(is_merchant_account: charged_using_gumroad_merchant_account?).to_f * 1000).round
      else
        if charged_using_gumroad_merchant_account?
          gumroad_fee_percentage_for_non_migrated_account
        else
          gumroad_fee_percentage_for_migrated_account
        end
      end
    end

    def calculate_custom_fee_per_thousand
      return if custom_fee_per_thousand.present?
      return if charge_discover_fee?

      if is_recurring_subscription_charge || is_updated_original_subscription_purchase
        self.custom_fee_per_thousand = subscription.original_purchase.custom_fee_per_thousand if subscription.original_purchase.custom_fee_per_thousand.present?
      elsif is_preorder_charge?
        self.custom_fee_per_thousand = preorder.authorization_purchase.custom_fee_per_thousand if preorder.authorization_purchase.custom_fee_per_thousand.present?
      elsif seller.custom_fee_per_thousand.present?
        self.custom_fee_per_thousand = seller.custom_fee_per_thousand
      end
    end

    def gumroad_flat_fee_per_thousand
      seller.waive_gumroad_fee_on_new_sales? && subscription.blank? && !is_preorder_charge? ? 0 : GUMROAD_FLAT_FEE_PER_THOUSAND
    end

    def flat_fee_applicable?
      # 10% flat fee is applicable to this purchase if it is not a recurring charge
      # on a subscription that started before the flat fee was introduced.
      subscription.blank? || subscription.flat_fee_applicable?
    end

    def gumroad_fee_percentage_for_non_migrated_account
      GUMROAD_FEE_PER_THOUSAND
    end

    def gumroad_fee_percentage_for_migrated_account
      GUMROAD_NON_PRO_FEE_PERCENTAGE
    end

    def calculate_taxes
      return unless self.price_cents
      return if price_cents == 0
      return unless tax_location_valid?
      return if seller.has_brazilian_stripe_connect_account?

      customer_country = country_or_ip_country
      country_code = Compliance::Countries.find_by_name(customer_country)&.alpha2

      in_eu_country = Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES.include?(country_code)
      in_australia = customer_country == Compliance::Countries::AUS.common_name
      in_singapore = customer_country == Compliance::Countries::SGP.common_name
      in_norway = customer_country == Compliance::Countries::NOR.common_name
      in_other_taxable_country = (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS).include?(country_code)
      in_other_taxable_country ||= (Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS).include?(country_code) && !link.is_physical?
      # Will return zip from shipping information if available before guessing from IP.
      # Shipping info is saved in Purchase during its creation the in the Purchases controller
      # See best_guess_zip for more detail on parsing / guessing zip
      postal_code = best_guess_zip

      calculator = SalesTaxCalculator.new(product: link,
                                          price_cents:,
                                          shipping_cents: shipping_cents.to_i,
                                          quantity:,
                                          buyer_location: { postal_code:, country: country_code, state:, ip_address: },
                                          buyer_vat_id: business_vat_id,
                                          from_discover: was_product_recommended)

      return unless in_eu_country || in_australia || in_singapore || in_norway || (in_other_taxable_country && Feature.active?("collect_tax_#{country_code.downcase}")) || calculator.is_us_taxable_state || calculator.is_ca_taxable

      tax_calculation = calculator.calculate

      if tax_calculation.zip_tax_rate.present?
        self.zip_tax_rate = tax_calculation.zip_tax_rate

        if tax_calculation.zip_tax_rate.is_seller_responsible
          self.tax_cents = tax_calculation.tax_cents
        else
          self.gumroad_tax_cents = tax_calculation.tax_cents
        end
      elsif tax_calculation.used_taxjar

        if tax_calculation.gumroad_is_mpf
          self.gumroad_tax_cents = tax_calculation.tax_cents
        else
          self.tax_cents = tax_calculation.tax_cents
        end

        if tax_calculation.taxjar_info.present?
          (purchase_taxjar_info || build_purchase_taxjar_info).tap do |info|
            info.combined_tax_rate = tax_calculation.taxjar_info[:combined_tax_rate]
            info.state_tax_rate = tax_calculation.taxjar_info[:state_tax_rate]
            info.county_tax_rate = tax_calculation.taxjar_info[:county_tax_rate]
            info.city_tax_rate = tax_calculation.taxjar_info[:city_tax_rate]
            info.gst_tax_rate = tax_calculation.taxjar_info[:gst_tax_rate]
            info.pst_tax_rate = tax_calculation.taxjar_info[:pst_tax_rate]
            info.qst_tax_rate = tax_calculation.taxjar_info[:qst_tax_rate]
            info.jurisdiction_state = tax_calculation.taxjar_info[:jurisdiction_state]
            info.jurisdiction_county = tax_calculation.taxjar_info[:jurisdiction_county]
            info.jurisdiction_city = tax_calculation.taxjar_info[:jurisdiction_city]
            info.save!
          end
        end
      end

      self.was_purchase_taxable = gumroad_tax_cents > 0 || tax_cents > 0
      self.was_tax_excluded_from_price = true
    end

    def calculate_shipping
      return unless link.is_physical
      return if country.blank?

      self.shipping_cents = if is_recurring_subscription_charge
        subscription.original_purchase.shipping_cents
      elsif is_preorder_charge?
        preorder.authorization_purchase.shipping_cents
      else
        shipping_rate = ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries.find_by_name(country)&.alpha2)
        shipping_rate.calculate_shipping_rate(quantity:, currency_type: link.price_currency_type)
      end
    end

    def validate_shipping
      return unless link.is_physical
      return if country.blank?

      if Compliance::Countries.blocked?(Compliance::Countries.find_by_name(country)&.alpha2)
        self.error_code = PurchaseErrorCode::BLOCKED_SHIPPING_COUNTRY
        errors.add :base, "The creator cannot ship the product to the country you have selected."
      elsif ShippingDestination.for_product_and_country_code(product: link, country_code: Compliance::Countries.find_by_name(country)&.alpha2).nil?
        self.error_code = PurchaseErrorCode::NO_SHIPPING_COUNTRY_CONFIGURED
        errors.add :base, "The creator cannot ship the product to the country you have selected."
      end
    end

    def validate_quantity
      return if quantity > 0

      self.error_code = PurchaseErrorCode::INVALID_QUANTITY
      errors.add :base, "Sorry, you've selected an invalid quantity."
    end

    def validate_offer_code
      return if errors.present?
      # accept the offer code that was used when the buyer preordered/subscribed
      return if is_preorder_charge? || is_recurring_subscription_charge || is_gift_receiver_purchase
      return if discount_code.blank?

      if offer_code.nil?
        self.error_code = PurchaseErrorCode::OFFER_CODE_INVALID
        errors.add :base, "Sorry, the discount code you wish to use is invalid."
        return
      end

      if offer_code.inactive?
        self.error_code = PurchaseErrorCode::OFFER_CODE_INACTIVE
        errors.add :base, "Sorry, the discount code you wish to use is inactive."
        return
      end

      unless quantity >= (offer_code.minimum_quantity || 0)
        self.error_code = PurchaseErrorCode::OFFER_CODE_INSUFFICIENT_QUANTITY
        errors.add :base, "Sorry, the discount code you wish to use has an unmet minimum quantity."
        return
      end

      return if offer_code.is_valid_for_purchase?(purchase_quantity: quantity)

      if offer_code.quantity_left > 0
        self.error_code = PurchaseErrorCode::EXCEEDING_OFFER_CODE_QUANTITY
        errors.add :base, "Sorry, the discount code you are using is invalid for the quantity you have selected."
      else
        self.error_code = PurchaseErrorCode::OFFER_CODE_SOLD_OUT
        errors.add :base, "Sorry, the discount code you wish to use has expired."
      end

      true
    end

    def validate_subscription
      return unless is_recurring_subscription_charge
      return if subscription.alive?

      self.error_code = PurchaseErrorCode::SUBSCRIPTION_INACTIVE
      errors.add :base, "This subscription has been canceled."
    end

    def perceived_price_cents_matches_price_cents
      return if errors.present?
      return if perceived_price_cents.nil?
      return if is_upgrade_purchase?
      return if is_commission_completion_purchase?
      return if is_applying_plan_change
      return if perceived_price_equals_link_price?
      return if customizable_price_that_has_not_changed?

      self.error_code = PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING
      errors.add(:price_cents, "The price just changed! Refresh the page for the updated price.")
      true
    end

    def determine_customized_price_cents
      customizable_price? ? perceived_price_cents : nil
    end

    def calculate_installment_payment_price_cents(total_price_cents)
      return unless is_installment_payment

      nth_installment = subscription&.purchases&.successful&.count || 0
      installment_payments = fetch_installment_plan.calculate_installment_payment_price_cents(total_price_cents)
      installment_payments[nth_installment] || installment_payments.last
    end

    def calculate_price_range_cents
      return unless price_range

      clean = price_range.to_s

      unless link.single_unit_currency?
        clean = clean.gsub(/[^-0-9.,]/, "") # allow commas for now
        if clean.rindex(/,/).present? && clean.rindex(/,/) >= clean.length - 3 # euro style!
          clean = clean.delete(".") # remove euro 1000^x delimiters
          clean = clean.tr(",", ".")             # replace euro comma with decimal
        end
      end
      clean = clean.gsub(/[^-0-9.]/, "")         # remove commas

      string_to_price_cents(link.price_currency_type.to_sym, clean)
    end

    def perceived_price_equals_link_price?
      [minimum_paid_price_cents, minimum_paid_price_cents - 1].include?(perceived_price_cents.to_i)
    end

    def customizable_price_that_has_not_changed?
      customizable_price? && perceived_price_cents.to_i >= minimum_paid_price_cents
    end

    def sold_out
      # Allow recurring billing and pre-order charges even after the product is sold out.
      return if does_not_count_towards_max_purchases
      return if link.max_purchase_count.nil?
      return if (link.sales_count_for_inventory + quantity) <= link.max_purchase_count

      if link.sales_count_for_inventory == link.max_purchase_count
        self.error_code = PurchaseErrorCode::PRODUCT_SOLD_OUT
        errors.add :base, "Sold out, please go back and pick another option."
      else
        self.error_code = PurchaseErrorCode::EXCEEDING_PRODUCT_QUANTITY
        errors.add :base, "You have chosen a quantity that exceeds what is available."
      end
    end

    def variants_available
      return if does_not_count_towards_max_purchases
      return if link.variant_categories_alive.empty?
      new_variants_available = new_variants.empty? || new_variants.map(&:available?).reduce { |a, e| a && e }

      return if new_variants_available && variants_available_for_quantity?

      if !new_variants_available
        self.error_code = PurchaseErrorCode::VARIANT_SOLD_OUT
        errors.add :base, "Sold out, please go back and pick another option."
      else
        self.error_code = PurchaseErrorCode::EXCEEDING_VARIANT_QUANTITY
        errors.add :base, "You have chosen a quantity that exceeds what is available."
      end
    end

    def variants_available_for_quantity?
      new_variants.map(&:quantity_left).each do |quantity_left|
        return false if quantity_left && quantity_left < quantity
      end

      true
    end

    def new_variants
      original_variant_attributes.present? ? variant_attributes - original_variant_attributes : variant_attributes
    end

    def variants_satisfied
      return if is_preorder_charge?
      return if is_commission_completion_purchase?
      return if is_recurring_subscription_charge
      return if link.native_type == Link::NATIVE_TYPE_COFFEE

      if link.skus_enabled
        return if variant_attributes.length == 1 && link.skus.alive.where(id: variant_attributes.first.id).exists?
        return if variant_attributes.empty? && link.skus.alive.empty?
      else
        return if (link.variant_categories_alive.map(&:id) & variant_attributes.map(&:variant_category_id)).count == link.variant_categories_alive.count
      end

      self.error_code = PurchaseErrorCode::MISSING_VARIANTS
      errors.add :base, "The product's variants have changed, please refresh the page!"
    end

    def product_is_sellable
      return if is_recurring_subscription_charge || is_preorder_charge? || is_test_purchase? || is_updated_original_subscription_purchase || is_commission_completion_purchase
      return unless seller.suspended? || !link.alive?

      self.error_code = PurchaseErrorCode::NOT_FOR_SALE
      errors.add :base, "This product is not currently for sale."
    end

    def product_is_not_blocked
      return if price_cents.zero?
      return if Feature.inactive?(:block_purchases_on_product)
      return if BlockedObject.product.find_active_object(link_id).blank?

      self.error_code = PurchaseErrorCode::TEMPORARILY_BLOCKED_PRODUCT
      errors.add :base, "Your card was not charged."
    end

    def validate_purchase_type
      if is_rental && link.buy_only?
        self.error_code = PurchaseErrorCode::NOT_FOR_RENT
        errors.add :base, "This product cannot be rented."
      elsif !is_rental && link.rent_only?
        self.error_code = PurchaseErrorCode::ONLY_FOR_RENT
        errors.add :base, "This product can only be rented."
      end
    end

    def not_double_charged
      return if is_bundle_product_purchase
      return if is_automatic_charge
      return if is_gift_receiver_purchase
      return if is_updated_original_subscription_purchase
      return if is_commission_completion_purchase
      return if link.allow_double_charges

      cancel_parallel_charge_intents

      limiting_purchase_states = [
        is_preorder_authorization ? "preorder_authorization_successful" : "successful",
        "in_progress"
      ]

      last_allowed_purchase_at = if is_upgrade_purchase? || link.quantity_enabled || link.is_physical || link.is_licensed
        10.seconds.ago
      else
        3.minutes.ago
      end

      recipient_email = is_gift_sender_purchase ? giftee_email : email
      already = self.class.where(
        email: recipient_email,
        ip_address:,
        link_id: link.id,
        purchase_state: limiting_purchase_states
      ).where("purchases.created_at > ?", last_allowed_purchase_at)

      already = already.where("purchases.id != ?", id) if id
      already = already.not_is_gift_sender_purchase unless is_gift_sender_purchase

      already += self.class.joins(:gift_given).where(
        gifts: { giftee_email: recipient_email },
        link:,
        purchase_state: limiting_purchase_states
      ) unless is_recurring_subscription_charge

      if variant_attributes.present?
        already = already.select do |purchase|
          purchase.variant_attributes.sort == variant_attributes.sort
        end
      end

      add_errors_for_existing_purchase(already)
    end

    def cancel_parallel_charge_intents
      potential_duplicates = self.class.where(
        browser_guid:,
        link_id: link.id,
        purchase_state: "in_progress"
      ).where.not(processor_payment_intent_id: nil)
       .where("created_at > ?", 1.hour.ago)

      potential_duplicates.each(&:cancel_charge_intent)
    end

    def add_errors_for_existing_purchase(purchases)
      if purchases.any?(&:successful?)
        errors.add :base, "You have already paid for this product. It has been emailed to you."
      elsif purchases.any?(&:preorder_authorization_successful?)
        errors.add :base, "You have already pre-ordered this product. A confirmation has been emailed to you."
      elsif purchases.any?(&:in_progress?)
        errors.add :base, "You have already attempted to purchase this product. We will email you shortly if the purchase is successful."
      end
    end

    def must_have_valid_email
      return if email && !email_changed?

      errors.add(:base, "valid email required") unless EmailFormatValidator.valid?(email)
    end

    def seller_is_link_user
      errors.add(:base, "link does not belong to user") unless seller == link.user
    end

    def free_trial_purchase_set_correctly
      return if !is_free_trial_purchase? && !link.free_trial_enabled?
      return if gift.present?

      if is_free_trial_purchase? && !link.free_trial_enabled? && !is_updated_original_subscription_purchase
        errors.add(:base, "free trial must be enabled on the product")
        return
      end

      if is_free_trial_purchase? && is_recurring_subscription_charge
        errors.add(:base, "recurring charges should not be marked as free trial purchases")
        return
      end

      if is_original_subscription_purchase? && !is_updated_original_subscription_purchase
        previous_purchases = link.sales.all_success_states.where(email:).where.not(subscription_id:)
        already_purchased = previous_purchases.exists?

        if already_purchased && is_free_trial_purchase?
          existing_subscriptions = Subscription.includes(:purchases).where(id: previous_purchases.map(&:subscription_id).compact)
          return if existing_subscriptions.all? { |s| s.purchases.successful.not_fully_refunded.not_chargedback_or_chargedback_reversed.exists? } # permit purchase if all existing subscriptions have at least one paid charge
          errors.add(:base, "You've already purchased this product and are ineligible for a free trial. Please visit the Manage Membership page to re-start or make changes to your subscription.")
        elsif !already_purchased && !is_free_trial_purchase?
          errors.add(:base, "purchase should be marked as a free trial purchase")
        end
      end
    end

    def gift_purchases_cannot_be_on_installment_plans
      return unless is_installment_payment?

      if is_gift_sender_purchase? || is_gift_receiver_purchase?
        errors.add(:base, "Gift purchases cannot be on installment plans.")
      end
    end

    def queue_product_cache_invalidation
      InvalidateProductCacheWorker.perform_in(1.minute, link_id)
    end

    def set_succeeded_at
      update(succeeded_at: Time.current) unless succeeded_at.present?
    end

    def schedule_subscription_jobs
      if subscription.charges_completed?
        EndSubscriptionWorker.perform_at(subscription.period.from_now, subscription.id)
      elsif is_free_trial_purchase?
        subscription.schedule_charge(subscription.free_trial_ends_at)
        FreeTrialExpiringReminderWorker.perform_at(subscription.free_trial_ends_at - Subscription::FREE_TRIAL_EXPIRING_REMINDER_EMAIL, subscription_id)
      else
        subscription.schedule_renewal_reminder
        subscription.schedule_charge(succeeded_at + subscription.period)
      end
    end

    def schedule_rental_expiration_reminder_emails
      return if is_gift_sender_purchase

      [7.days, 3.days, 1.day].each do |time_till_rental_expiration|
        SendRentalExpiresSoonEmailWorker.perform_in(
          UrlRedirect::TIME_TO_WATCH_RENTED_PRODUCT_AFTER_PURCHASE - time_till_rental_expiration,
          id,
          time_till_rental_expiration.to_i)
      end
    end

    def schedule_workflow_jobs
      # for gifts, only send a webhook for the giftee's purchase, not for the gifter's purchase
      return if is_gift_sender_purchase
      return if is_recurring_subscription_charge

      after_commit do
        next if destroyed?
        ScheduleWorkflowEmailsWorker.perform_in(5.seconds, id)
      end
    end

    def send_refunded_notification_webhook
      return if is_gift_sender_purchase

      PostToPingEndpointsWorker.perform_in(5.seconds, id, url_parameters, ResourceSubscription::REFUNDED_RESOURCE_NAME)
    end

    def score_product
      ScoreProductWorker.perform_in(5.seconds, link.id) if run_risk_checks?
    end

    def check_purchase_heuristics
      CheckPurchaseHeuristicsWorker.perform_in(5.seconds, id) if run_risk_checks?
    end

    def log_transition
      logger.info "Purchase: purchase ID #{id} transitioned to #{purchase_state}"
    end

    def tax_location_valid?
      return true if country.nil?
      return true if link.is_physical || link.require_shipping
      return true if card_country.nil? && country == ip_country
      return true if ip_country == link.user.compliance_country_code

      country_code = Compliance::Countries.find_by_name(country)&.alpha2
      ip_country_code = Compliance::Countries.find_by_name(ip_country)&.alpha2

      ip_and_card_locations = [ip_country_code, card_country]

      taxable_countries = Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES | Compliance::Countries::GST_APPLICABLE_COUNTRY_CODES | Compliance::Countries::OTHER_TAXABLE_COUNTRY_CODES | Compliance::Countries::NORWAY_VAT_APPLICABLE_COUNTRY_CODES
      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_ALL_PRODUCTS.each do |country_code|
        taxable_countries << country_code if Feature.active?("collect_tax_#{country_code.downcase}")
      end
      Compliance::Countries::COUNTRIES_THAT_COLLECT_TAX_ON_DIGITAL_PRODUCTS.each do |country_code|
        taxable_countries << country_code if Feature.active?("collect_tax_#{country_code.downcase}") && !link.is_physical?
      end

      # Perform location checks only when taxed in a taxable country
      # OR
      # Both card country and IP country are in a taxable country
      card_and_ip_country_are_taxable = (ip_and_card_locations & taxable_countries).size == 2
      card_and_ip_country_are_taxable ||= (ip_and_card_locations.uniq & taxable_countries).size == 1
      return true if !country_code.in?(taxable_countries) && !card_and_ip_country_are_taxable

      # Reset taxes if we see an election of a taxable country and our basis locations aren't in those countries - final safety measure
      return false if country_code.in?(taxable_countries) && (ip_and_card_locations & taxable_countries).empty?

      # Country matched
      return true if country_code.in?(ip_and_card_locations)

      self.error_code = PurchaseErrorCode::TAX_VALIDATION_FAILED
      errors.add :base, "We could not validate the location you selected. Please review."
      false
    end

    def format_price_in_cents(price_cents, format: :long)
      formatted_price = format_just_price_in_cents(price_cents, displayed_price_currency_type)
      price = price_for_recurrence
      return formatted_price if price.nil?

      formatted_price_with_recurrence(formatted_price, price.recurrence, subscription.try(:charge_occurence_count), format:)
    end

    def update_product_search_index!
      link.enqueue_index_update_for(%w[is_recommendable])

      # sales_volume needs to be updated asynchronously, because:
      # - it's based on Product::Stats#total_usd_cents, which itself uses the Purchase index data
      # - purchases are indexed asynchronously, and the index is also internally refreshed asynchronously
      # If we indexed sales_volume synchronously, it's likely to fetch outdated data from the purchases index,
      # thus not reflecting the latest purchase that was just made here.
      SendToElasticsearchWorker.perform_in(5.seconds, link.id, "update", ["sales_volume", "total_fee_cents", "past_year_fee_cents"])
    end

    def send_failure_email
      after_commit do
        next if destroyed?

        if error_code == PurchaseErrorCode::NET_NEGATIVE_SELLER_REVENUE
          ContactingCreatorMailer.negative_revenue_sale_failure(id).deliver_later(queue: "critical")
        elsif paid? && charge_processor_id.in?([PaypalChargeProcessor.charge_processor_id, BraintreeChargeProcessor.charge_processor_id])
          CustomerMailer.paypal_purchase_failed(id).deliver_later(queue: "critical")
        end
      end
    end

    def license_json
      selected_license = linked_license

      return {} unless selected_license

      {
        license_key: selected_license.serial,
        license_id: selected_license.external_id,
        license_disabled: selected_license.disabled?,
        is_multiseat_license: is_multiseat_license?
      }
    end

    def subscription_duration
      price_for_recurrence&.recurrence
    end

    def attach_credit_card_to_purchaser
      return if purchaser.credit_card

      latest_successful_purchase =
        purchaser.purchases.successful.with_credit_card_id.order(created_at: :desc).first

      return unless latest_successful_purchase

      purchaser.credit_card_id = latest_successful_purchase.credit_card_id
      purchaser.save!
    end

    def assign_default_rental_expired
      return unless is_rental_changed?
      self.rental_expired = is_rental? ? false : nil
      true
    end

    def assign_is_multiseat_license
      self.is_multiseat_license = link.is_multiseat_license?
    end

    def price_for_recurrence
      price || subscription&.price
    end

    def downcase_email
      return if email.blank?
      self.email = email.downcase
    end

    def run_risk_checks?
      price_cents > 0 && !not_charged? && charged_using_gumroad_merchant_account?
    end

    def all_workflows
      link.workflows.alive + seller.workflows.alive.seller_or_audience_type
    end

    def geo_info
      @geo_info ||= GeoIp.lookup(ip_address)
    end

    def has_cached_offer_code?
      purchase_offer_code_discount.present?
    end

    def purchasing_power_parity_factor
      @_purchasing_power_parity_factor ||= PurchasingPowerParityService.new.get_factor(Compliance::Countries.find_by_name(ip_country)&.alpha2, seller)
    end

    def trigger_iffy_moderation
      probability = $redis.get(RedisKey.iffy_moderation_probability).to_f || 0.001
      if rand < probability
        Iffy::Product::IngestJob.perform_async(link.id)
      end
    end

    def fetch_installment_plan
      installment_plan || subscription&.last_payment_option&.installment_plan
    end
end
