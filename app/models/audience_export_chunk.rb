# frozen_string_literal: true

class AudienceExportChunk < ApplicationRecord
  belongs_to :audience_export

  serialize :member_ids, type: Array, coder: YAML
  serialize :members_data, type: Array, coder: YAML
end
