# frozen_string_literal: true

class PurchaseParameters
  include ParameterObject

  attribute :email, :string
  attribute :price_cents, :integer
  attribute :product_id, :integer
  attribute :buyer_id, :integer
  attribute :payment_method_id, :string
  attribute :ip_address, :string
  attribute :user_agent, :string
  attribute :browser_guid, :string
  attribute :affiliate_id, :integer
  attribute :offer_code, :string
  attribute :quantity, :integer, default: 1
  attribute :is_gift, :boolean, default: false
  attribute :gift_recipient_email, :string
  attribute :custom_fields, :string

  validates :email, presence: true, email: true
  validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :product_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :gift_recipient_email, email: true, if: :is_gift?

  def free_purchase?
    price_cents == 0
  end

  def gift_purchase?
    is_gift == true
  end
end
