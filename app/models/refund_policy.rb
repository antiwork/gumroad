# frozen_string_literal: true

class RefundPolicy < ApplicationRecord
  include ExternalId

  has_paper_trail

  belongs_to :seller, class_name: "User"

  stripped_fields :title, :fine_print, transform: -> { ActionController::Base.helpers.strip_tags(_1) }

  validates_presence_of :seller
  validates :fine_print, length: { maximum: 3_000 }

  def as_json(*)
    {
      fine_print:,
      id: external_id,
      title:,
    }
  end
end
