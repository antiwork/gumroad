# frozen_string_literal: true

FactoryBot.define do
  factory :guardian_empty, class: Guardian do
    first_name { "John" }
    last_name { "Guardian" }
    email { "guardian@example.com" }
    phone { "+14155551234" }
    date_of_birth { 40.years.ago.to_date }
    street_address { "123 Guardian St" }
    city { "San Francisco" }
    state { "California" }
    zip_code { "94107" }
    country { "United States" }
  end

  factory :guardian, parent: :guardian_empty do
    sequence(:stripe_person_id) { |n| "person_guardian_#{n}" }
    individual_tax_id { "123456789" }
    stripe_tos_accepted { true }
    stripe_tos_ip { "127.0.0.1" }
    stripe_processing_tos_accepted { true }
  end

  factory :guardian_canada, parent: :guardian do
    country { "Canada" }
    state { "ON" }
    zip_code { "K1A 0A6" }
    job_title { "Director" }
  end

  factory :guardian_japan, parent: :guardian do
    country { "Japan" }
    state { "Tokyo" }
    zip_code { "100-0001" }
    first_name_kanji { "太郎" }
    last_name_kanji { "山田" }
    first_name_kana { "タロウ" }
    last_name_kana { "ヤマダ" }
    building_number { "101" }
    street_address_kanji { "東京都千代田区" }
    street_address_kana { "トウキョウトチヨダク" }
  end

  factory :guardian_uae, parent: :guardian do
    country { "United Arab Emirates" }
    state { "Dubai" }
    zip_code { "00000" }
    nationality { "US" }
  end
end
