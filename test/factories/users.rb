# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    email { generate :email }
    username { generate :username }
    password { "-42Q_.c_3628Ca!mW-xTJ8v*" }
    confirmed_at { Time.current }
    user_risk_state { "not_reviewed" }
    payment_address { generate :email }

    current_sign_in_ip { Faker::Internet.ip_v4_address }
    last_sign_in_ip    { Faker::Internet.ip_v4_address }
    account_created_ip { Faker::Internet.ip_v4_address }
    pre_signup_affiliate_request_processed { true }

    transient do
      unpaid_balance_cents { nil }
      skip_enabling_two_factor_authentication { true }
      tipping_enabled { false }
      discover_boost_enabled { false }
    end

    after(:build) do |user, evaluator|
      # Disable 2FA by default in tests to avoid updating many test cases individually.
      user.skip_enabling_two_factor_authentication = evaluator.skip_enabling_two_factor_authentication
    end

    after(:create) do |user, evaluator|
      if evaluator.unpaid_balance_cents
        user.balances.destroy_all
        create(:balance, user:, amount_cents: evaluator.unpaid_balance_cents)
      end
      user.update_column(:flags, user.flags ^ User.flag_mapping["flags"][:tipping_enabled]) unless evaluator.tipping_enabled
      user.update_column(:flags, user.flags ^ User.flag_mapping["flags"][:discover_boost_enabled]) unless evaluator.discover_boost_enabled
    end

    factory :buyer_user do
      buyer_signup { true }
      username { generate(:fixed_username) }
      email { generate(:fixed_email) }

      after(:create) do |user|
        create(:purchase, purchaser_id: user.id)
      end

      trait :affiliate do
        after(:create) do |user|
          create(:direct_affiliate, affiliate_user: user)
        end
      end
    end

    factory :unconfirmed_user do
      confirmed_at { nil }
      pre_signup_affiliate_request_processed { false }
    end

    factory :named_seller do
      name { "Seller" }
      username { "seller" }
      email { "seller@example.com" }
      payment_address { generate(:fixed_email) }
    end

    factory :named_user do
      name { "Gumbot" }
      username { generate(:fixed_username) }
      email { generate(:fixed_email) }
      payment_address { generate(:fixed_email) }

      trait :admin do
        is_team_member { true }

        name { "Gumlord" }
      end
    end

    factory :admin_user do
      is_team_member { true }
    end

    factory :affiliate_user do
      sequence(:username) do |n|
        "thisisme#{n}"
      end

      after(:create) do |user|
        create(:user_compliance_info, user:)
      end
    end

    factory :compliant_user do
      user_risk_state { "compliant" }
    end

    factory :recommendable_user do
      user_risk_state { "compliant" }

      trait :named_user do
        name { "Gumbot" }
        username { generate(:fixed_username) }
        email { generate(:fixed_email) }
        payment_address { generate(:fixed_email) }
      end
    end

    factory :user_with_compliance_info do
      user_risk_state { "compliant" }

      after(:create) do |user|
        create(:user_compliance_info, user:)
      end
    end

    factory :singaporean_user_with_compliance_info do
      user_risk_state { "compliant" }

      after(:create) do |user|
        create(:user_compliance_info_singapore, user:)
      end
    end

    factory :tos_user do
      user_risk_state { "suspended_for_tos_violation" }
    end

    factory :user_with_compromised_password do
      username { "test-user" }
      password { "password" }
      to_create { |instance| instance.save(validate: false) }
    end

    trait :with_avatar do
      after(:create) do |user|
        blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "smilie.png")
        blob.analyze
        user.avatar.attach(blob)
      end
    end

    trait :with_subscribe_preview do
      after(:create) do |user|
        user.subscribe_preview.attach(
          io: File.open(Rails.root.join("spec", "support", "fixtures", "subscribe_preview.png")),
          filename: "subscribe_preview.png",
          content_type: "image/png"
        )
      end
    end

    trait :with_annual_report do
      transient do
        year { Time.current.year }
      end

      after(:create) do |user, evaluator|
        blob = ActiveStorage::Blob.create_and_upload!(
          io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "followers_import.csv"), "text/csv"),
          filename: "Financial Annual Report #{evaluator.year}.csv",
          metadata: { year: evaluator.year }
        )
        blob.analyze
        user.annual_reports.attach(blob)
      end
    end

    trait :with_bio do
      bio { Faker::Lorem.sentence }
    end

    trait :with_twitter_handle do
      twitter_handle { Faker::Lorem.word }
    end

    trait :deleted do
      deleted_at { Time.current }
    end

    trait :without_username do
      username { nil }
    end

    trait :eligible_for_service_products do
      created_at { User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day }
    end

    trait :suspended do
      user_risk_state { "suspended_for_tos_violation" }
    end

    trait :flagged_for_tos_violation do
      user_risk_state { "flagged_for_tos_violation" }
    end
  end
end
