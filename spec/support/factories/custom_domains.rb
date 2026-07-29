# frozen_string_literal: true

FactoryBot.define do
  factory :custom_domain do
    association :user
    domain { Faker::Internet.domain_name(subdomain: true) }
  end

  trait :with_product do
    association :product
    user { nil }
  end

  # A domain the seller has actually proven they control: DNS verification
  # passed and a current SSL certificate is in place. CustomDomain#active?
  # requires both, and code that builds or trusts custom-domain URLs checks
  # active? rather than mere presence.
  #
  # The certificate timestamp is written after create because saving a new
  # domain clears it (see CustomDomain#reset_ssl_certificate_issued_at, which
  # runs whenever the domain attribute changes).
  trait :verified_with_certificate do
    state { "verified" }

    after(:create) do |custom_domain|
      custom_domain.set_ssl_certificate_issued_at!
    end
  end
end
