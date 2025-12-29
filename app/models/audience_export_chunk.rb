# frozen_string_literal: true

class AudienceExportChunk < ApplicationRecord
  belongs_to :export, class_name: "AudienceExport"
  serialize :audience_member_ids, type: Array, coder: YAML
  serialize :audience_members_data, type: Array, coder: YAML
end
