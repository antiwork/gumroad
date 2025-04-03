# frozen_string_literal: true

FactoryBot.define do
  factory :discord_integration do
    server_id { "0" }
    server_name { "Gaming" }
    username { "gumbot" }
  end
end
