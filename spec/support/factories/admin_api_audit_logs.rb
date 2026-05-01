# frozen_string_literal: true

FactoryBot.define do
  factory :admin_api_audit_log do
    association :actor_user, factory: :admin_user
    admin_api_token { association :admin_api_token, actor_user: }
    action { "purchases.refund" }
    route { "/api/internal/admin/purchases/123/refund" }
    http_method { "POST" }
    response_status { 200 }
    created_at { Time.current }
  end
end
