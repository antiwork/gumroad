# frozen_string_literal: true

class Dispute < ApplicationRecord
  has_paper_trail

  include ExternalId

  belongs_to :seller, class_name: "User", optional: true
  belongs_to :purchase, optional: true
  belongs_to :charge, optional: true
  belongs_to :service_charge, optional: true
  has_many :credits
  has_many :balance_transactions
  has_one :dispute_evidence

  before_validation :assign_seller, on: :create, if: :disputable_has_seller?

  validates :state, :event_created_at, presence: true
  validates :seller, presence: true, if: :disputable_has_seller?
  validate :disputable_must_be_present
  validate :only_one_disputable_present

  # Dispute state transitions:
  #
  # created → → → → initiated → → → → → closed
  #             ↓       ↓
  #             ↓       ↓              ↱ won
  #             ↓ → formalized → → → →   ↓↑
  #                                    ↳ lost
  #
  # created = A dispute has been created and is in the process of being recorded. All disputes will start in this state.
  # initiated = A dispute has finished being created, has been initiated at the bank but is not formalized and does not yet have financial consequences.
  # formalized = A dispute has finished being created, and is formalized, having financial consequences.
  # won = A formalized dispute has been closed in our favor, the financial consequences were reversed in a Credit.
  # lost = A formalized dispute has been closed in the payers favor.
  #
  # At the time of object creation a dispute may be initiated or formalized, because disputes will start in the initiated
  # state if we are being told about the dispute before it's been formalized, or it may start in the formalized state immediately
  # if the dispute is being created and already has financial consequences from day-one. For this reason the initial state is `nil`
  # because there's no clear default initial state.
  #
  # Dispute objects are a new concept and there are many chargebacks recorded on purchases that do not have a dispute object.
  # When an event occurs about an old dispute like won/lost, we're creating the dispute object then. So there may be disputes
  # that have not gone through either the initiated or formalized state in 2015. This shouldn't be the case in 2016+.
  #
  state_machine :state, initial: :created do
    after_transition any => any, :do => :log_transition

    before_transition any => :initiated,  do: ->(dispute) { dispute.initiated_at = Time.current }
    before_transition any => :closed,     do: ->(dispute) { dispute.closed_at = Time.current }
    before_transition any => :formalized, do: ->(dispute) { dispute.formalized_at = Time.current }
    before_transition any => :won,        do: ->(dispute) { dispute.won_at = Time.current }
    before_transition any => :lost,       do: ->(dispute) { dispute.lost_at = Time.current }

    event :mark_initiated do
      transition [:created] => :initiated
    end

    event :mark_closed do
      transition %i[created initiated] => :closed
    end

    event :mark_formalized do
      transition %i[created initiated] => :formalized
    end

    event :mark_won do
      transition %i[created formalized lost] => :won
    end

    event :mark_lost do
      transition %i[created formalized won] => :lost
    end
  end

  STRIPE_REASONS = %w[
    credit_not_processed
    duplicate
    fraudulent
    general
    product_not_received
    product_unacceptable
    subscription_canceled
    unrecognized
  ]
  STRIPE_REASONS.each do |stripe_reason|
    self.const_set("REASON_#{stripe_reason.upcase}", stripe_reason)
  end

  def disputable
    charge || purchase || service_charge
  end

  def purchases
    charge&.purchases || [purchase]
  end

  private
    def log_transition
      logger.info "Dispute: dispute ID #{id} transitioned to #{state}"
    end

    def disputable_must_be_present
      return if disputable.present?

      errors.add(:base, "A Disputable object must be provided.")
    end

    def only_one_disputable_present
      errors.add(:base, "Only one Disputable object must be provided.") unless [charge, purchase, service_charge].one?(&:present?)
    end

    def disputable_has_seller? # this method exists because ServiceCharge does not have a seller
      disputable.is_a?(Purchase) || disputable.is_a?(Charge)
    end

    def assign_seller
      self.seller = disputable.seller
    end
end
