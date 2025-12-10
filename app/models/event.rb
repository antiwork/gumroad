# frozen_string_literal: true

class Event < ApplicationRecord
  include TimestampScopes
  include FlagShihTzu

  # Events with names listed below are created and kept forever.
  # We also create events that aren't in this list if they have a user_id (see Events#created_event),
  # but they're automatically deleted after a while (see DeleteOldUnusedEventsWorker).
  PERMITTED_NAMES = %w[
    audience_callout_dismissal
    chargeback
    first_purchase_on_profile_visit
    post_view
    product_refund_policy_fine_print_view
    purchase
    service_charge
    settlement_declined
    refund
  ]
  PERMITTED_NAMES.each do |name|
    const_set("NAME_#{name.upcase}", name)
  end

  has_one :installment_event

  belongs_to :purchase, optional: true
  belongs_to :service_charge, optional: true
  belongs_to :user, optional: true
  delegate :external_id, to: :user, prefix: true, allow_nil: true

  has_flags 1 => :from_profile,
            2 => :was_product_recommended,
            3 => :is_recurring_subscription_charge,
            4 => :manufactured,
            5 => :on_custom_domain,
            6 => :from_multi_overlay,
            7 => :from_seo,
            :column => "visit_id",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_accessor :extra_features

  with_options if: -> { event_name == NAME_PURCHASE } do
    validates_presence_of :purchase_id, :link_id
  end

  scope :by_browser_guid,                         ->(guid) { where(browser_guid: guid) }
  scope :by_ip_address,                           ->(ip) { where(ip_address: ip) }
  scope :purchase,                                -> { where(event_name: NAME_PURCHASE) }
  scope :service_charge,                          -> { where(event_name: NAME_SERVICE_CHARGE) }
  scope :link_view,                               -> { where(event_name: "link_view") }
  scope :post_view,                               -> { where(event_name: NAME_POST_VIEW) }
  scope :service_charge_successful,               -> { service_charge.where(purchase_state: "successful") }
  scope :purchase_successful,                     -> { purchase.where(purchase_state: "successful") }
  scope :not_refunded,                            -> { purchase_successful.where("events.refunded is null or events.refunded = 0") }
  scope :for_products,                            ->(products) { where(link_id: products) }
end
