# frozen_string_literal: true

class CreatorEmailClickSummary
  include Mongoid::Document

  index({ installment_id: 1 }, { unique: true, name: "installment_index" })

  field :installment_id, type: Integer
  field :total_unique_clicks, type: Integer
  field :urls, type: Hash
end
