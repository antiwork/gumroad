# frozen_string_literal: true

class AudienceExportChunk < ApplicationRecord
  belongs_to :audience_export

  # Use project convention for JSON serialization
  include JsonData
  attr_json_data_accessor :member_ids, :members_data
  # Store all chunk data in the json_data column

  validates :audience_export, presence: true
end
