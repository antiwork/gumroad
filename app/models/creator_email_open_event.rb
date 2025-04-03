# frozen_string_literal: true

class CreatorEmailOpenEvent
  include Mongoid::Document
  include Mongoid::Timestamps

  index({ mailer_method: 1, mailer_args: 1 }, { unique: true, name: "recipient_index" })
  index({ installment_id: 1 }, { name: "installment_index" })

  field :mailer_method, type: String
  field :mailer_args, type: String
  field :installment_id, type: Integer
  field :open_timestamps, type: Array
  field :open_count, type: Integer
end
