# frozen_string_literal: true

FactoryBot.define do
  factory :purchase do
    association :link, factory: :product
    seller { link.user }
    price_cents { link.price_cents }
    shipping_cents { 0 }
    tax_cents { 0 }
    gumroad_tax_cents { 0 }
    total_transaction_cents { price_cents + gumroad_tax_cents }
    displayed_price_cents { price_cents - shipping_cents - tax_cents }
    email { generate :email }
    stripe_fingerprint { price_cents == 0 ? nil : "shfbeg5142fff" }
    stripe_transaction_id { price_cents == 0 ? nil : "2763276372637263" }
    card_type do
      if charge_processor_id == PaypalChargeProcessor.charge_processor_id
        CardType::PAYPAL
      else
        "visa"
      end
    end
    card_visual do
      if charge_processor_id == PaypalChargeProcessor.charge_processor_id
        "jane@paypal.com"
      else
        "**** **** **** 4062"
      end
    end
    card_country { "US" }
    ip_address { Faker::Internet.ip_v4_address }
    browser_guid { generate :browser_guid }
    charge_processor_id do
      if chargeable
        chargeable.charge_processor_id
      else
        stripe_transaction_id ? StripeChargeProcessor.charge_processor_id : nil
      end
    end
    merchant_account { stripe_transaction_id ? MerchantAccount.gumroad(charge_processor_id) : nil }
    purchase_state { "successful" }
    succeeded_at { Time.current }
    flow_of_funds { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, total_transaction_cents) }

    after(:build) { |purchase| purchase.send(:calculate_fees) }

    trait :with_custom_fee do
      transient do
        fee_cents { nil }
      end

      before(:create) do |purchase, evaluator|
        if evaluator.fee_cents
          purchase.fee_cents = evaluator.fee_cents
        end
      end
    end

    trait :with_review do
      after(:create) do |purchase|
        create(:product_review, purchase:, rating: 5)
      end
    end

    trait :with_license do
      after(:create) do |purchase|
        create(:license, purchase:)
      end
    end

    trait :from_seller do
      link { create(:product, user: seller) }
    end

    trait :gift_receiver do
      is_gift_receiver_purchase { true }
      purchase_state { "gift_receiver_purchase_successful" }
    end

    trait :gift_sender do
      is_gift_sender_purchase { true }
    end

    factory :purchase_2 do
      price_cents { 20_00 }
      created_at { "2012-03-22" }
      stripe_fingerprint { "shfbeggg5142fff" }
      stripe_transaction_id { "276322276372637263" }
    end

    factory :free_purchase do
      price_cents { 0 }
      displayed_price_cents { 0 }
      card_type { nil }
      card_visual { nil }
      stripe_fingerprint { nil }
      stripe_transaction_id { nil }
    end

    factory :test_purchase do
      purchase_state { "in_progress" }
      purchaser { link.user }
      email { link.user.email }
      after(:create, &:mark_test_successful!)
    end

    factory :preorder_authorization_purchase do
      purchase_state { "preorder_authorization_successful" }
    end

    factory :failed_purchase do
      purchase_state { "failed" }
    end

    factory :refunded_purchase do
      stripe_refunded { true }

      after(:create) do |purchase|
        create(:refund, purchase:, amount_cents: purchase.price_cents)
      end
    end

    trait :refunded do
      stripe_refunded { true }

      after(:create) do |purchase|
        create(:refund, purchase:, amount_cents: purchase.price_cents)
      end
    end

    factory :disputed_purchase do
      chargeable { build(:chargeable_success_charge_disputed) }
      chargeback_date { Time.current }
    end

    trait :with_dispute do
      after(:create) do |purchase|
        create(:dispute, purchase:)
      end
    end

    factory :physical_purchase do
      full_name { "barnabas" }
      street_address { "123 barnabas street" }
      city { "barnabasville" }
      state { "CA" }
      country { "United States" }
      zip_code { "94114" }
    end

    factory :purchase_in_progress do
      purchase_state { "in_progress" }
      factory :purchase_with_balance do
        after(:create, &:update_balance_and_mark_successful!)
      end
    end

    factory :membership_purchase do
      association :link, factory: :membership_product
      is_original_subscription_purchase { true }

      transient do
        tier { nil }
      end

      before(:create) do |purchase, evaluator|
        purchase.variant_attributes = evaluator.tier.present? ? [evaluator.tier] : purchase.tiers
      end

      after(:create) do |purchase, evaluator|
        purchase.subscription ||= create(:subscription, link: purchase.link)
        purchase.save!

        if purchase.is_installment_payment && purchase.installment_plan.present?
          payment_option = purchase.subscription.last_payment_option
          if payment_option && !payment_option.installment_plan_snapshot
            create(:installment_plan_snapshot,
                   payment_option: payment_option,
                   number_of_installments: purchase.installment_plan.number_of_installments,
                   recurrence: purchase.installment_plan.recurrence,
                   total_price_cents: purchase.total_price_before_installments || purchase.price_cents)
          end
        end
      end
    end

    factory :free_trial_membership_purchase do
      association :link, factory: [:membership_product, :with_free_trial_enabled]
      is_original_subscription_purchase { true }
      is_free_trial_purchase { true }
      should_exclude_product_review { true }
      purchase_state { "not_charged" }
      succeeded_at { nil }

      before(:create) do |purchase, evaluator|
        purchase.variant_attributes = purchase.tiers
      end

      after(:create) do |purchase, evaluator|
        purchase.subscription ||= create(:subscription, link: purchase.link, user: purchase.purchaser, free_trial_ends_at: Time.current + purchase.link.free_trial_duration)
        purchase.variant_attributes = purchase.tiers
        purchase.save!

        if purchase.is_installment_payment && purchase.installment_plan.present?
          payment_option = purchase.subscription.last_payment_option
          if payment_option && !payment_option.installment_plan_snapshot
            create(:installment_plan_snapshot,
                   payment_option: payment_option,
                   number_of_installments: purchase.installment_plan.number_of_installments,
                   recurrence: purchase.installment_plan.recurrence,
                   total_price_cents: purchase.total_price_before_installments || purchase.price_cents)
          end
        end
      end
    end

    factory :recurring_membership_purchase do
      association :link, factory: :membership_product
      is_original_subscription_purchase { false }

      before do
        purchase.variant_attributes = purchase.tiers
      end

      after(:create) do |purchase|
        purchase.subscription ||= create(:subscription, link: purchase.link)
        purchase.subscription.purchases << build(:membership_purchase)
        purchase.save!

        if purchase.is_installment_payment && purchase.installment_plan.present?
          payment_option = purchase.subscription.last_payment_option
          if payment_option && !payment_option.installment_plan_snapshot
            create(:installment_plan_snapshot,
                   payment_option: payment_option,
                   number_of_installments: purchase.installment_plan.number_of_installments,
                   recurrence: purchase.installment_plan.recurrence,
                   total_price_cents: purchase.total_price_before_installments || purchase.price_cents)
          end
        end
      end
    end

    factory :installment_plan_purchase do
      association :link, :with_installment_plan, factory: :product
      is_original_subscription_purchase { true }
      is_installment_payment { true }

      before(:create) do |purchase|
        purchase.installment_plan = purchase.link.installment_plan
        purchase.set_price_and_rate
      end

      after(:create) do |purchase, evaluator|
        purchase.subscription ||= create(:subscription, link: purchase.link, is_installment_plan: true, user: purchase.purchaser)
        purchase.save!

        if purchase.is_installment_payment && purchase.installment_plan.present?
          payment_option = purchase.subscription.last_payment_option
          if payment_option && !payment_option.installment_plan_snapshot
            create(:installment_plan_snapshot,
                   payment_option: payment_option,
                   number_of_installments: purchase.installment_plan.number_of_installments,
                   recurrence: purchase.installment_plan.recurrence,
                   total_price_cents: purchase.total_price_before_installments || purchase.price_cents)
          end
        end
      end
    end

    factory :recurring_installment_plan_purchase do
      association :link, :with_installment_plan, factory: :product
      is_original_subscription_purchase { false }
      is_installment_payment { true }

      before(:create) do |purchase|
        purchase.installment_plan = purchase.link.installment_plan
        purchase.set_price_and_rate
      end
    end

    factory :call_purchase do
      link { create(:call_product, :available_for_a_year) }

      after(:build) do |purchase|
        purchase.call ||= build(:call, purchase:)
      end
    end

    factory :commission_deposit_purchase do
      is_commission_deposit_purchase { true }
      association :link, factory: :commission_product
      association :credit_card

      after(:build) do |purchase|
        purchase.set_price_and_rate
      end
    end
  end
end
