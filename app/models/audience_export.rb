# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"
  has_many :chunks, class_name: "AudienceExportChunk", foreign_key: :export_id, dependent: :delete_all

  serialize :options, type: Hash, coder: YAML
  validates_presence_of :options
end
