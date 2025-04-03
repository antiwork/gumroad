# frozen_string_literal: true

FactoryBot.define do
  factory :imported_customer do
    association :importing_user, factory: :user
    email { generate :email }
    purchase_date { Time.current }
    link_id { 1 }
  end
end
