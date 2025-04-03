# frozen_string_literal: true

class SalesExport < ApplicationRecord
  belongs_to :recipient, class_name: "User"
  # We use :delete_all instead of :destroy to prevent needlessly loading
  # a lot of data in memory (column `purchases_data`).
  has_many :chunks, class_name: "SalesExportChunk", foreign_key: :export_id, dependent: :delete_all
  serialize :query, type: Hash, coder: YAML
  validates_presence_of :query
end
