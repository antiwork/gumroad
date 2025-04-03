# frozen_string_literal: true

class Preorder < ApplicationRecord
  include ExternalId
  include AfterCommitEverywhere

  belongs_to :preorder_link, optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :purchaser, class_name: "User", optional: true
  has_many :purchases
  has_one :url_redirect
  has_one :credit_card

  validates :preorder_link, presence: true
  validates :seller, presence: true

  # Preorder state transitions:
  #
  #                                         →   charge_successful
  #                                         ↑
  # in_progress  →  authorization_successful
  #      ↓                                  ↓
  # authorization_failed                    →   cancelled
  #
  state_machine(:state, initial: :in_progress) do
    before_transition in_progress: :authorization_successful, do: :authorization_purchase_successful?
    before_transition authorization_successful: :charge_successful, do: :charge_purchase_successful?

    after_transition in_progress: :authorization_successful, do: :associate_credit_card_to_preorder
    after_transition in_progress: %i[test_authorization_successful authorization_successful], do: :send_preorder_notifications
    after_transition authorization_successful: :charge_successful, do: :mark_authorization_purchase_as_concluded_successfully
    after_transition authorization_successful: :cancelled, do: :mark_authorization_purchase_as_concluded_unsuccessfully
    after_transition authorization_successful: :cancelled, do: :send_cancellation_emails

    after_transition any => any, :do => :log_transition

    event :mark_authorization_failed do
      transition in_progress: :authorization_failed
    end

    event :mark_authorization_successful do
      transition in_progress: :authorization_successful
    end

    event :mark_test_authorization_successful do
      transition in_progress: :test_authorization_successful
    end

    event :mark_charge_successful do
      transition authorization_successful: :charge_successful
    end

    event :mark_cancelled do
      transition authorization_successful: :cancelled
    end
  end

  scope :in_progress,                                   -> { where(state: "in_progress") }
  scope :authorization_successful,                      -> { where(state: "authorization_successful") }
  scope :authorization_failed,                          -> { where(state: "authorization_failed") }
  scope :charge_successful,                             -> { where(state: "charge_successful") }
  scope :authorization_successful_or_charge_successful, -> { where("preorders.state = 'authorization_successful' or preorders.state = 'charge_successful'") }

  delegate :link, to: :preorder_link

  def is_authorization_successful?
    state == "authorization_successful"
  end

  def is_cancelled?
    state == "cancelled"
  end

  def authorization_purchase
    # The preorder's first purchase is always the credit card authorization (customer creation)
    purchases.first
  end

  def authorize!
    authorization_purchase.process!

    purchase_errors = authorization_purchase.errors
    if is_test_preorder?
      authorization_purchase.mark_test_preorder_successful!
    elsif purchase_errors&.any?
      errors.add(:base, purchase_errors.full_messages[0])
    elsif authorization_purchase.setup_intent&.requires_action?
      # Leave in `in_progress` state until the UI action is completed
    else
      authorization_purchase.mark_preorder_authorization_successful!
    end

    # Don't keep the preorder's association with an invalid object because its state transition will fail
    self.purchases = [] unless authorization_purchase.persisted?
  end

  # Public: Charges the credit card associated with the preorder.
  #
  # NOTE: The caller is responsible for setting the state of the preorder.
  #
  # ip_address  - The ip address of the buyer assuming this is not an automatic charge (update card scenario).
  # browser_guid  - The guid of the buyer assuming this is not an automatic charge (update card scenario).
  # purchase_params - Purchase params to use with the purchase created when doing the charge. Items in this may be
  #                   overwritten by the preorder logic.
  #
  # Returns the purchase object representing the charge, or nil if this preorder is not in a chargeable state.
  def charge!(ip_address: nil, browser_guid: nil, purchase_params: {})
    return nil if link.is_in_preorder_state || !is_authorization_successful?
    return nil if purchases.in_progress_or_successful_including_test.any?

    purchase_params.merge!(email: authorization_purchase.email,
                           price_range: authorization_purchase.displayed_price_cents / (preorder_link.link.single_unit_currency? ? 1 : 100.0),
                           perceived_price_cents: authorization_purchase.displayed_price_cents,
                           browser_guid: browser_guid || authorization_purchase.browser_guid,
                           ip_address: ip_address || authorization_purchase.ip_address,
                           ip_country: ip_address.present? ? GeoIp.lookup(ip_address).try(:country_name) : authorization_purchase.ip_country,
                           ip_state: ip_address.present? ? GeoIp.lookup(ip_address).try(:region_name) : authorization_purchase.ip_state,
                           referrer: authorization_purchase.referrer,
                           full_name: authorization_purchase.full_name,
                           street_address: authorization_purchase.street_address,
                           country: authorization_purchase.country,
                           state: authorization_purchase.state,
                           zip_code: authorization_purchase.zip_code,
                           city: authorization_purchase.city,
                           quantity: authorization_purchase.quantity,
                           was_product_recommended: authorization_purchase.was_product_recommended)
    purchase = Purchase.new(purchase_params)
    purchase.preorder = self
    purchase.credit_card = credit_card
    purchase.offer_code = authorization_purchase.offer_code
    purchase.variant_attributes = authorization_purchase.variant_attributes
    purchase.purchaser = purchaser
    purchase.link = link
    purchase.seller = seller
    purchase.credit_card_zipcode = authorization_purchase.credit_card_zipcode
    purchase.affiliate = authorization_purchase.affiliate if authorization_purchase.affiliate.try(:alive?)
    authorization_purchase.purchase_custom_fields.each { purchase.purchase_custom_fields << _1.dup }
    if authorization_purchase.purchase_sales_tax_info
      purchase.business_vat_id = authorization_purchase.purchase_sales_tax_info.business_vat_id
      elected_country_code = authorization_purchase.purchase_sales_tax_info.elected_country_code
      purchase.sales_tax_country_code_election = elected_country_code if elected_country_code
    end
    purchase.ensure_completion do
      purchase.process!
      if purchase.errors.present?
        begin
          purchase.mark_failed!
        rescue StateMachines::InvalidTransition => e
          logger.error "Purchase for preorder error: Could not create purchase for preorder ID #{id} because #{e}"
        end
      else
        purchase.update_balance_and_mark_successful!
        after_commit do
          ActivateIntegrationsWorker.perform_async(purchase.id)
        end
      end
    end

    # it is important that we link RecommendedPurchaseInfo with the charge purchase, successful or not, for metrics
    if purchase.was_product_recommended
      rec_purchase_info = authorization_purchase.recommended_purchase_info
      rec_purchase_info.purchase = purchase
      rec_purchase_info.save
    end

    purchases << purchase
    purchase
  end

  def is_test_preorder?
    seller == purchaser
  end

  def mobile_json_data
    if charge_purchase_successful?
      preorder_charge_purchase = purchases.last
      return preorder_charge_purchase.url_redirect.product_json_data
    end
    result = link.as_json(mobile: true)
    preorder_data = { external_id:, release_at: preorder_link.release_at }
    result[:preorder_data] = preorder_data
    if authorization_purchase
      result[:purchase_id] = authorization_purchase.external_id
      result[:purchased_at] = authorization_purchase.created_at
      result[:user_id] = authorization_purchase.purchaser.external_id if authorization_purchase.purchaser
      result[:product_updates_data] = authorization_purchase.update_json_data_for_mobile
      result[:is_archived] = authorization_purchase.is_archived
    end
    result
  end

  private
    def mark_authorization_purchase_as_concluded_successfully
      authorization_purchase.mark_preorder_concluded_successfully
    end

    def mark_authorization_purchase_as_concluded_unsuccessfully
      authorization_purchase.mark_preorder_concluded_unsuccessfully
    end

    def send_preorder_notifications
      CustomerMailer.preorder_receipt(id).deliver_later(queue: "critical", wait: 3.seconds)

      return unless seller.enable_payment_email?

      ContactingCreatorMailer.notify(authorization_purchase.id, true).deliver_later(queue: "critical", wait: 3.seconds)
    end

    def associate_credit_card_to_preorder
      self.credit_card = authorization_purchase.credit_card
    end

    def log_transition
      logger.info "Preorder: preorder ID #{id} transitioned to #{state}"
    end

    def authorization_purchase_successful?
      authorization_purchase.purchase_state == if is_test_preorder?
        "test_preorder_successful"
      else
        "preorder_authorization_successful"
      end
    end

    def charge_purchase_successful?
      purchases.last.purchase_state == "successful"
    end

    def send_cancellation_emails(transition)
      params = transition.args.first
      return if params && params[:auto_cancelled]

      CustomerLowPriorityMailer.preorder_cancelled(id).deliver_later(queue: "low")
      ContactingCreatorMailer.preorder_cancelled(id).deliver_later(queue: "critical")
    end
end
