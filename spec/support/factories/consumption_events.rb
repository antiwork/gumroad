# frozen_string_literal: true

FactoryBot.define do
  factory :consumption_event do
    product_file_id { create(:product_file).id }
    url_redirect_id { create(:url_redirect).id }
    purchase_id { create(:purchase).id }
    link_id { create(:product).id }
    event_type { ConsumptionEvent::EVENT_TYPE_WATCH }
    platform { Platform::WEB }
    consumed_at { Time.current }
  end
end
