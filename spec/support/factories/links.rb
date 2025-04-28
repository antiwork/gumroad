# frozen_string_literal: true

FactoryBot.define do
  factory :product, class: Link do
    name { "The Works of Edgar Gumstein" }
    description { "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes." }
    user { create(:user) }
    price_cents { 100 }
    display_product_reviews { true }

    transient do
      tag { nil }
      active_integrations { [] }
    end

    after(:create) do |product, evaluator|
      if !evaluator.tag.nil?
        product.tag!(evaluator.tag)
      end
      product.active_integrations |= evaluator.active_integrations
    end

    trait :with_custom_receipt do
      custom_receipt { "Rerum reiciendis doloremque consequuntur sed fuga repellendus ut delectus soluta omnis ipsam ullam sunt qui quos velit iusto eos neque repellat suscipit ratione inventore ex." }
    end

    trait :with_custom_fields do
      after(:create) do |product|
        product.custom_fields << [
          create(:custom_field, name: "Text field", seller: product.user, field_type: "text"),
          create(:custom_field, name: "Checkbox field", seller: product.user, field_type: "checkbox", required: true),
          create(:custom_field, name: "http://example.com", seller: product.user, field_type: "terms", required: true)
        ]
      end
    end

    trait :with_youtube_preview do
      after(:create) do |product|
        create(:asset_preview_youtube, link: product)
      end
    end

    trait :with_films_taxonomy do
      taxonomy { Taxonomy.find_or_create_by(slug: "films") }
    end

    trait :with_design_taxonomy do
      taxonomy { Taxonomy.find_or_create_by(slug: "design") }
    end

    trait :with_youtube_preview do
      after(:create) do |product|
        create(:asset_preview_youtube, link: product)
      end
    end

    trait :with_installment_plan do
      price_cents { 3000 }
      installment_plan { create(:product_installment_plan, link: instance, number_of_installments: 3) }
    end

    trait :is_physical do
      after(:create) do |product|
        product.require_shipping = true
        product.native_type = "physical"
        product.skus_enabled = true
        product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE,
                                                                 one_item_rate_cents: 0,
                                                                 multiple_items_rate_cents: 0)
        product.skus << Sku.new(price_difference_cents: 0, name: "DEFAULT_SKU", is_default_sku: true)
        product.is_physical = true
        product.quantity_enabled = true
        product.should_show_sales_count = true
        product.save!
      end
    end

    trait :is_subscription do
      is_recurring_billing { true }
      subscription_duration { :monthly }
      is_tiered_membership { false }
    end

    trait :is_collab do
      is_collab { true }

      transient do
        collaborator_cut { 30_00 }
        collaborator { nil }
      end

      after(:create) do |product, evaluator|
        collaborator = evaluator.collaborator || create(:collaborator, seller: product.user)
        create(:product_affiliate, product:, affiliate: collaborator, affiliate_basis_points: evaluator.collaborator_cut)
      end
    end

    trait :recommendable do
      with_films_taxonomy
      user { create(:recommendable_user, name: "gumbo") }

      after(:create) do |product|
        create(:purchase, :with_review, link: product, created_at: 1.week.ago)
        product.reload
      end
    end

    trait :staff_picked do
      recommendable

      after(:create) do |product|
        product.create_staff_picked_product!(updated_at: product.updated_at)
      end
    end

    trait :with_custom_receipt_unsafe_html do
      custom_receipt do
        <<-CUSTOM_RECEIPT
<strong>Thanks for purchasing my product. Check out my website for more.</strong>
<br />
https://google.com/a?c&d
My email is test@gmail.com <i>Reach out and say hi!</i>
<meta http-equiv="refresh" content="0; URL='http://example.com/'" />
<!--
<em>You cannot see this.</em>
<script>var a = 2;</script>
<style>a {color: red;}</style>
<iframe src="http://example.com" />
:)
        CUSTOM_RECEIPT
      end
    end

    trait :bundle do
      name { "Bundle" }
      description { "This is a bundle of products" }
      is_bundle { true }

      bundle_products do
        build_list(:bundle_product, 2, bundle: instance) do |bundle_product, i|
          bundle_product.product.update!(name: "Bundle Product #{i + 1}")
        end
      end
    end

    trait :unpublished do
      draft { true }
      purchase_disabled_at { Time.current }
    end

    factory :product_with_files do
      transient do
        files_count { 2 }
      end

      after(:create) do |product, evaluator|
        evaluator.files_count.times do |n|
          create(:product_file, link: product, size: 300 * (n + 1), display_name: "link-#{n}-file", description: "product-#{n}-file-description")
        end
      end
    end

    factory :product_with_pdf_file do
      after(:create) do |product|
        create(:readable_document, link: product, pagelength: 3, size: 50, display_name: "Display Name", description: "Description")
      end
    end

    factory :product_with_pdf_files_with_size do
      after(:create) do |product|
        create(:readable_document, link: product, size: 50, display_name: "Display Name")
        create(:listenable_audio, link: product, size: 310, display_name: "Display Name 2")
        create(:streamable_video, link: product, size: 502, display_name: "Display Name 3")
      end
    end

    factory :product_with_video_file do
      after(:create) do |product|
        create(:streamable_video, link: product)
      end
    end

    factory :product_with_file_and_preview do
      name { "The Wrath of the River" }
      description { "A poem not for the lighthearted, but the heavy. Like lead." }
      preview { Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png") }
    end

    factory :physical_product do
      is_physical
    end

    factory :subscription_product do
      is_subscription

      factory :subscription_product_with_versions do
        after(:create) do |product|
          category = create(:variant_category, title: "Category", link: product)
          create(:variant, variant_category: category, name: "Untitled 1")
          create(:variant, variant_category: category, name: "Untitled 2")
        end
      end
    end

    factory :product_with_digital_versions do
      after(:create) do |product|
        category = create(:variant_category, title: "Category", link: product)
        create(:variant, variant_category: category, name: "Untitled 1")
        create(:variant, variant_category: category, name: "Untitled 2")
      end
    end

    factory :product_with_discord_integration do
      after(:create) do |product|
        integration = create(:discord_integration, server_id: "0")
        product.active_integrations << integration
        product.save!
      end
    end

    factory :product_with_circle_integration do
      after(:create) do |product|
        integration = create(:circle_integration)
        product.active_integrations << integration
        product.save!
      end
    end

    factory :membership_product do
      is_recurring_billing { true }
      subscription_duration { :monthly }
      is_tiered_membership { true }
      native_type { Link::NATIVE_TYPE_MEMBERSHIP }

      trait :with_free_trial_enabled do
        is_recurring_billing { true }
        subscription_duration { :monthly }
        is_tiered_membership { true }
        free_trial_enabled { true }
        free_trial_duration_amount { 1 }
        free_trial_duration_unit { :week }
      end

      factory :membership_product_with_preset_tiered_pricing do
        transient do
          recurrence_price_values do
            [
              { "monthly": { enabled: true, price: 3 } },
              { "monthly": { enabled: true, price: 5 } }
            ]
          end
        end

        after(:create) do |product, evaluator|
          tier_category = product.tier_category
          first_tier = tier_category.variants.first
          first_tier.update!(name: "First Tier")
          second_tier = create(:variant, variant_category: tier_category, name: "Second Tier")
          first_tier.save_recurring_prices!(evaluator.recurrence_price_values[0])
          second_tier.save_recurring_prices!(evaluator.recurrence_price_values[1])
          evaluator.recurrence_price_values[2..-1].each_with_index do |recurrences, index|
            tier = create(:variant, variant_category: tier_category, name: "Tier #{index + 3}")
            tier.save_recurring_prices!(recurrences)
          end
          product.tiers.reload
        end
      end

      factory :membership_product_with_preset_tiered_pwyw_pricing do
        after(:create) do |product|
          tier_category = product.tier_category
          first_tier = tier_category.variants.first
          first_tier.update!(name: "First Tier", customizable_price: true)
          second_tier = create(:variant, variant_category: tier_category, name: "Second Tier")
          recurrence_values = BasePrice::Recurrence.all.index_with do |recurrence_key|
            {
              enabled: true,
              price: "500",
              suggested_price: "600"
            }
          end
          first_tier.save_recurring_prices!(recurrence_values)
          second_tier.save_recurring_prices!(recurrence_values)
        end
      end
    end

    factory :call_product do
      user { create(:user, :eligible_for_service_products) }
      native_type { Link::NATIVE_TYPE_CALL }

      transient do
        durations { [30] }
      end

      after(:create) do |product, evaluator|
        category = product.variant_categories.first
        evaluator.durations.each do |duration|
          category.variants.create!(duration_in_minutes: duration, name: "#{duration} minutes")
        end
      end

      trait :available_for_a_year do
        call_availabilities { build_list(:call_availability, 1, call: @instance, start_time: 1.day.ago, end_time: 1.year.from_now) }
      end
    end

    factory :commission_product do
      user { create(:user, :eligible_for_service_products) }
      native_type { Link::NATIVE_TYPE_COMMISSION }
      price_cents { 200 }
    end

    factory :coffee_product do
      user { create(:user, :eligible_for_service_products) }
      native_type { Link::NATIVE_TYPE_COFFEE }
    end
  end
end
