# frozen_string_literal: true

FactoryBot.define do
  factory :installment, aliases: [:post] do
    association :link, factory: :product
    seller { link&.user }
    message { Faker::Lorem.paragraph }
    name { Faker::Book.title }
    send_emails { true }
    installment_type { "product" }
    shown_on_profile { false }
    deleted_at { nil }
    allow_comments { true }

    factory :published_installment do
      published_at { Time.current }
    end

    trait :published do
      published_at { Time.current }
    end

    factory :variant_post, aliases: [:variant_installment] do
      installment_type { Installment::VARIANT_TYPE }
      association :base_variant, factory: :variant
    end

    factory :product_post, aliases: [:product_installment] do
      installment_type { Installment::PRODUCT_TYPE }
    end

    factory :seller_post, aliases: [:seller_installment] do
      installment_type { Installment::SELLER_TYPE }
      seller factory: :user
      link { nil }
    end

    factory :follower_post do # follower_installment has attachments
      installment_type { Installment::FOLLOWER_TYPE }
      seller factory: :user
      link { nil }
    end

    factory :affiliate_post do # affiliate_installment has attachments
      installment_type { Installment::AFFILIATE_TYPE }
      seller factory: :user
      link { nil }
    end

    factory :audience_installment, aliases: [:audience_post] do
      message { Faker::Lorem.paragraph }
      name { Faker::Book.title }
      installment_type { Installment::AUDIENCE_TYPE }
      send_emails { true }
      link { nil }
      seller factory: :user
    end

    factory :scheduled_installment do
      ready_to_publish { true }
      after(:create) do |installment|
        create(:installment_rule, installment:)
      end
    end

    factory :workflow_installment, aliases: [:workflow_post] do
      send_emails { true }
      workflow { create(:product_workflow, seller:, link:) }
      installment_type { workflow.workflow_type }
      base_variant { workflow.base_variant }
      is_for_new_customers_of_workflow { !workflow.send_to_past_customers }
      published_at { workflow.published_at }
      workflow_installment_published_once_already { published_at.present? }
      json_data { workflow.json_data }

      after(:create) do |installment|
        create(:installment_rule, installment:, delayed_delivery_time: 0)
      end
    end
  end

  factory :follower_installment, class: Installment do
    message { "Here is a new PDF for you" }
    name { "A new file!" }
    installment_type { Installment::FOLLOWER_TYPE }
    send_emails { true }
    link { nil }
    seller factory: :user
    after(:create) do |installment|
      create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf", link: nil)
    end
  end

  factory :affiliate_installment, class: Installment do
    message { "Here is a new PDF for you" }
    name { "A new file!" }
    installment_type { Installment::AFFILIATE_TYPE }
    send_emails { true }
    link { nil }
    seller factory: :user
    after(:create) do |installment|
      create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf", link: nil)
    end
  end
end
