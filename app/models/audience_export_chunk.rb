# frozen_string_literal: true

class AudienceExportChunk < ApplicationRecord
  belongs_to :audience_export

  include JsonData
  attr_json_data_accessor :member_ids, :members_data

  validates :audience_export, presence: true
end
