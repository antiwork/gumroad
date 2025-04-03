# frozen_string_literal: true

FactoryBot.define do
  sequence(:browser_guid) do |n|
    ["SDJKF-#{n}-#{rand(99_999)}-DSFKLLFK", "SDFJKLDF-#{n}-#{rand(999_999)}-JDSFKLDSF", "JKDDSFJKSFD-#{n}-#{rand(99_999)}-SDFJ"].sample
  end
  sequence(:username) { |n| "edgar#{SecureRandom.hex(4)}#{n}" }
  sequence(:email) { |n| "edgar#{SecureRandom.hex(4)}_#{n}@gumroad.com" }
  sequence(:fixed_username) { |n| "edgar#{n}" }
  sequence(:fixed_email) { |n| "edgar_#{n}@gumroad.com" }
  sequence(:ip) { ["4.167.234.0", "199.21.86.138", "12.38.32.0", "64.115.250.0"].sample }
  sequence(:token) { |n| "#{("a".."z").to_a.shuffle.join}#{n}" }
  sequence(:fixed_timestamp) { |n| DateTime.parse("2021-12-02 01:22:10") + n.minutes }
end
