# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"
  # We use :delete_all instead of :destroy to prevent needlessly loading
  # a lot of data in memory (column `audience_data`).
  has_many :chunks, class_name: "AudienceExportChunk", foreign_key: :export_id, dependent: :delete_all
  serialize :options, type: Hash, coder: YAML
  validates_presence_of :options
end

