# frozen_string_literal: true

FactoryBot.define do
  factory :subscription do
    association :link, factory: :product
    user
    is_installment_plan { false }

    transient do
      price { nil }
      purchase_email { nil }
    end

    before(:create) do |subscription, evaluator|
      if subscription.is_installment_plan
        installment_plan = subscription.link.installment_plan
        if installment_plan.present?
          payment_option = create(
            :payment_option,
            subscription:,
            price: evaluator.price || subscription.link.default_price,
            installment_plan: installment_plan
          )
          subscription.payment_options << payment_option
          subscription.charge_occurrence_count = installment_plan.number_of_installments
        else
          # Create a temporary payment_option without validation to satisfy subscription validation
          # Tests will destroy this and create their own with proper installment_plan
          payment_option = build(
            :payment_option,
            subscription:,
            price: evaluator.price || subscription.link.default_price,
            installment_plan: nil
          )
          payment_option.save!(validate: false)
          subscription.payment_options << payment_option
        end
      else
        payment_option = create(
          :payment_option,
          subscription:,
          price: evaluator.price || subscription.link.default_price,
          installment_plan: nil
        )
        subscription.payment_options << payment_option
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
