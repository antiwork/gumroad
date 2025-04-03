# frozen_string_literal: true

class UtmLinkDrivenSale < ApplicationRecord
  belongs_to :utm_link
  belongs_to :utm_link_visit
  belongs_to :purchase

  validates :purchase_id, uniqueness: { scope: :utm_link_visit_id }
end
