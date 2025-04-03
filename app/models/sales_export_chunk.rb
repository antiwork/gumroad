# frozen_string_literal: true

class SalesExportChunk < ApplicationRecord
  belongs_to :export, class_name: "SalesExport"
  serialize :purchase_ids, type: Array, coder: YAML
  serialize :custom_fields, type: Array, coder: YAML
  serialize :purchases_data, type: Array, coder: YAML
end
