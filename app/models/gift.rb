# frozen_string_literal: true

class Gift < ApplicationRecord
  include FlagShihTzu

  stripped_fields :gifter_email, :giftee_email

  belongs_to :gifter_purchase, class_name: "Purchase", optional: true
  belongs_to :giftee_purchase, class_name: "Purchase", optional: true
  belongs_to :link, optional: true

  validates :giftee_email, presence: true, email_format: true
  validates :gifter_email, presence: true, email_format: true

  has_flags 1 => :is_recipient_hidden

  state_machine(:state, initial: :in_progress) do
    before_transition in_progress: :successful, do: :everything_successful?
    event :mark_successful do
      transition in_progress: :successful
    end
    event :mark_failed do
      transition in_progress: :failed
    end
  end

  scope :successful, -> { where(state: "successful") }

  private
    def everything_successful?
      gifter_purchase.present? && giftee_purchase.present? && gifter_purchase.successful? && giftee_purchase.gift_receiver_purchase_successful?
    end
end
