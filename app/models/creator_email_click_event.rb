# frozen_string_literal: true

class CreatorEmailClickEvent
  include Mongoid::Document
  include Mongoid::Timestamps

  # This is a key that represents the link by which to view attached files on an installment
  VIEW_ATTACHMENTS_URL = "view_attachments_url"

  index({ installment_id: 1, mailer_method: 1, mailer_args: 1, click_url: 1 }, { unique: true, name: "click_index" })

  field :mailer_method, type: String
  field :mailer_args, type: String
  field :installment_id, type: Integer
  field :click_url, type: String
  field :click_timestamps, type: Array
  field :click_count, type: Integer
end
