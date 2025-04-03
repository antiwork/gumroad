# frozen_string_literal: true

class ProductFolder < ApplicationRecord
  include ExternalId
  include Deletable
  scope :in_order, -> { order(position: :asc) }
  belongs_to :link, foreign_key: "product_id", optional: true

  validates_presence_of :name

  def as_json(options = {})
    {
      id: external_id,
      name:
    }
  end
end
