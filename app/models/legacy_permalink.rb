# frozen_string_literal: true

class LegacyPermalink < ApplicationRecord
  belongs_to :product, class_name: "Link", optional: true

  validates :permalink, presence: true, format: { with: /\A[a-zA-Z0-9_-]+\z/ }, uniqueness: { case_sensitive: false }
  validates_presence_of :product
end
