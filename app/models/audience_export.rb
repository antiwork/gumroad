# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  include JsonData

  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"
  has_many :audience_export_chunks, dependent: :delete_all

  attr_json_data_accessor :followers, default: false
  attr_json_data_accessor :customers, default: false
  attr_json_data_accessor :affiliates, default: false

  validate :at_least_one_audience_type_selected

  private
    def at_least_one_audience_type_selected
      return if followers || customers || affiliates

      errors.add(:base, "At least one audience type (followers, customers, or affiliates) must be selected")
    end
end
