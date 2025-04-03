# frozen_string_literal: true

FactoryBot.define do
  factory :customer_email_info do
    purchase
    email_name { "receipt" }
    state { "created" }

    factory :customer_email_info_sent do
      state { "sent" }
      sent_at { Time.current }

      factory :customer_email_info_delivered do
        state { "delivered" }
        delivered_at { Time.current }

        factory :customer_email_info_opened do
          state { "opened" }
          opened_at { Time.current }
        end
      end
    end
  end
end
