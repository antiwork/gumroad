# frozen_string_literal: true

FactoryBot.define do
  factory :installment_rule, aliases: [:post_rule] do
    installment
    to_be_published_at { 1.week.from_now }
    time_period { "hour" }
  end
end
