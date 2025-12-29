# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :user
  belongs_to :recipient, class_name: "User"
  has_many :chunks, class_name: "AudienceExportChunk", foreign_key: :export_id, dependent: :delete_all
  serialize :audience_options, type: Hash, coder: YAML
  validates_presence_of :audience_options
end
