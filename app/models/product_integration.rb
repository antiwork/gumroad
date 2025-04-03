# frozen_string_literal: true

class ProductIntegration < ApplicationRecord
  include Deletable

  belongs_to :product, class_name: "Link", optional: true
  belongs_to :integration, optional: true

  validates_presence_of :product_id, :integration_id
  validates_uniqueness_of :integration_id, scope: %i[product_id deleted_at], unless: :deleted?
end
