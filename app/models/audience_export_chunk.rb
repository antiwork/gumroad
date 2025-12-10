# frozen_string_literal: true

class AudienceExportChunk < ApplicationRecord
  belongs_to :export, class_name: "AudienceExport"

  serialize :member_ids, type: Array, coder: YAML
  serialize :csv_data, type: Array, coder: YAML
end
