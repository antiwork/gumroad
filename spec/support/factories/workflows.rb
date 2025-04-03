# frozen_string_literal: true

FactoryBot.define do
  factory :workflow do
    association :seller, factory: :user
    link { create(:product, user: seller) }
    name { "my workflow" }
    workflow_type { "product" }
    workflow_trigger { nil }

    factory :audience_workflow do
      workflow_type { Workflow::AUDIENCE_TYPE }
      link { nil }
    end

    factory :seller_workflow do
      workflow_type { Workflow::SELLER_TYPE }
      link { nil }
    end

    factory :product_workflow do
      workflow_type { Workflow::PRODUCT_TYPE }
    end

    factory :variant_workflow do
      workflow_type { Workflow::VARIANT_TYPE }
      association :base_variant, factory: :variant
    end

    factory :follower_workflow do
      workflow_type { Workflow::FOLLOWER_TYPE }
      link { nil }
    end

    factory :affiliate_workflow do
      workflow_type { Workflow::AFFILIATE_TYPE }
      link { nil }
    end

    factory :abandoned_cart_workflow do
      workflow_type { Workflow::ABANDONED_CART_TYPE }
      link { nil }

      after(:create) do |workflow|
        installment = build(:workflow_installment, workflow:, seller: workflow.seller)
        installment.published_at = workflow.published_at
        installment.name = "You left something in your cart"
        installment.message = "When you're ready to buy, complete checking out.<product-list-placeholder />Thanks!"
        installment.save!
      end
    end
  end
end
