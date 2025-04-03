# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_integration do
    purchase { create(:purchase) }
    integration { create(:circle_integration) }

    before(:create) do |purchase_integration|
      purchase_integration.purchase.link.active_integrations |= [purchase_integration.integration]
    end

    factory :discord_purchase_integration do
      integration { create(:discord_integration) }
      discord_user_id { "user-0" }
    end
  end
end
