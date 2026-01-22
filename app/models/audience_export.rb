# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"

  has_many :audience_export_chunks, dependent: :delete_all

  include JsonData
  attr_json_data_accessor :options, :filename

  validates :seller, :recipient, presence: true
end
