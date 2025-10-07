# frozen_string_literal: true

FactoryBot.define do
  factory :subscription do
    association :link, factory: :product
    user

    transient do
      price { nil }
      purchase_email { nil }
    end

    before(:create) do |subscription, evaluator|
      installment_plan = subscription.is_installment_plan ? subscription.link.installment_plan : nil

      # Build payment option but don't validate/save yet
      # The subscription needs payment_options to be present for validation
      payment_option = subscription.payment_options.build(
        price: evaluator.price || subscription.link.default_price,
        installment_plan:
      )

      # Manually set snapshot fields for installment plans to satisfy validation
      # The before_create callback would normally set these, but we're building manually
      if subscription.is_installment_plan && installment_plan
        payment_option.number_of_installments = installment_plan.number_of_installments
        payment_option.recurrence = installment_plan.recurrence
        subscription.charge_occurrence_count = installment_plan.number_of_installments
      end
    end

    factory :subscription_without_user do
      user { nil }

      transient do
        email { generate :email }
      end

      before(:create) do |subscription, evaluator|
        purchase = create(:purchase, link: subscription.link, is_original_subscription_purchase: true, email: evaluator.email)
        subscription.purchases << purchase
      end
    end
  end
end
