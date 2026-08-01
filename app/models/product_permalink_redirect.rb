# frozen_string_literal: true

class ProductPermalinkRedirect < ApplicationRecord
  belongs_to :product, class_name: "Link"
  belongs_to :seller, class_name: "User"

  validates :permalink, presence: true, format: { with: /\A[a-zA-Z0-9_-]+\z/ }, uniqueness: { case_sensitive: false, scope: :seller_id }
end
