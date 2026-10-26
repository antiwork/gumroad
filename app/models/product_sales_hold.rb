# frozen_string_literal: true

# A staff block on new sales of one listing. Kept out of Link's shared flags column so that a stale
# save of an unrelated flag cannot drop it, and so that other admin takedowns keep their own marker.
class ProductSalesHold < ApplicationRecord
  EXTERNAL_ID_LENGTH = 21
  EXTERNAL_ID_ALPHABET = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  belongs_to :product, class_name: "Link"
  belongs_to :held_by, class_name: "User"
  belongs_to :released_by, class_name: "User", optional: true

  before_validation :generate_external_id, on: :create

  validates :external_id, presence: true

  scope :active, -> { where(released_at: nil) }

  def active?
    released_at.nil?
  end

  private
    def generate_external_id
      return if external_id.present?

      loop do
        self.external_id = Array.new(EXTERNAL_ID_LENGTH) { EXTERNAL_ID_ALPHABET[SecureRandom.random_number(EXTERNAL_ID_ALPHABET.length)] }.join
        break unless self.class.exists?(external_id:)
      end
    end
end
