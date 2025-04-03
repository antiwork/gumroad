# frozen_string_literal: true

FactoryBot.define do
  factory :user_compliance_info_empty, class: UserComplianceInfo do
    user
  end

  factory :user_compliance_info, parent: :user_compliance_info_empty do
    first_name { "Chuck" }
    last_name { "Bartowski" }
    street_address { "address_full_match" }
    city { "San Francisco" }
    state { "California" }
    zip_code { "94107" }
    country { "United States" }
    verticals { [Vertical::PUBLISHING] }
    is_business { false }
    has_sold_before { false }
    individual_tax_id { "000000000" }
    birthday { Date.new(1901, 1, 1) }
    dba { "Chuckster" }
    phone { "0000000000" }
  end

  factory :user_compliance_info_singapore, parent: :user_compliance_info_empty do
    first_name { "Chuck" }
    last_name { "Bartowski" }
    street_address { "address_full_match" }
    city { "Singapore" }
    state { "Singapore" }
    zip_code { "12345" }
    country { "Singapore" }
    verticals { [Vertical::PUBLISHING] }
    is_business { false }
    has_sold_before { false }
    individual_tax_id { "000000000" }
    birthday { Date.new(1980, 1, 2) }
    dba { "Chuckster" }
    nationality { "US" }
    phone { "0000000000" }
  end

  factory :user_compliance_info_canada, parent: :user_compliance_info do
    zip_code { "M4C 1T2" }
    state { "BC" }
    country { "Canada" }
  end

  factory :user_compliance_info_korea, parent: :user_compliance_info do
    zip_code { "10169" }
    country { "Korea, Republic of" }
  end

  factory :user_compliance_info_business, parent: :user_compliance_info do
    is_business { true }
    business_name { "Buy More, LLC" }
    business_street_address { "address_full_match" }
    business_city { "Burbank" }
    business_state { "California" }
    business_zip_code { "91506" }
    business_country { "United States" }
    business_type { UserComplianceInfo::BusinessTypes::LLC }
    business_tax_id { "000000000" }
    dba { "Buy Moria" }
    business_phone { "0000000000" }
  end

  factory :user_compliance_info_uae, parent: :user_compliance_info_empty do
    first_name { "Chuck" }
    last_name { "Bartowski" }
    street_address { "address_full_match" }
    city { "Dubai" }
    state { "Dubai" }
    zip_code { "51133" }
    country { "United Arab Emirates" }
    verticals { [Vertical::PUBLISHING] }
    is_business { false }
    has_sold_before { false }
    individual_tax_id { "000000000" }
    birthday { Date.new(1901, 1, 1) }
    dba { "Chuckster" }
    phone { "0000000000" }
    nationality { "US" }
  end

  factory :user_compliance_info_uae_business, parent: :user_compliance_info_uae do
    is_business { true }
    business_name { "Buy More, LLC" }
    business_street_address { "address_full_match" }
    business_city { "Dubai" }
    business_state { "Dubai" }
    business_zip_code { "51133" }
    business_country { "United Arab Emirates" }
    business_type { "llc" }
    business_tax_id { "000000000" }
    dba { "Buy Moria" }
    business_phone { "0000000000" }
  end

  factory :user_compliance_info_mex_business, parent: :user_compliance_info do
    city { "Mexico City" }
    state { "Estado de México" }
    zip_code { "01000" }
    country { "Mexico" }
    is_business { true }
    business_name { "Buy More, LLC" }
    business_street_address { "address_full_match" }
    business_city { "Mexico City" }
    business_state { "Estado de México" }
    business_zip_code { "01000" }
    business_country { "Mexico" }
    business_type { "llc" }
    business_tax_id { "000000000000" }
    dba { "Buy Moria" }
    business_phone { "0000000000" }
  end
end
