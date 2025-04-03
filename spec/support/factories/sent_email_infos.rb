# frozen_string_literal: true

FactoryBot.define do
  factory :sent_email_info do
    key { SecureRandom.hex(20) }
  end
end
