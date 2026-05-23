# frozen_string_literal: true

FactoryBot.define do
  factory :creator_contacting_customers_email_info do
    purchase
    installment
    email_name { "purchase_installment" }
    state { "created" }

    factory :creator_contacting_customers_email_info_sent do
      state { "sent" }
      sent_at { Time.current }

      factory :creator_contacting_customers_email_info_delivered do
        state { "delivered" }
        delivered_at { Time.current }

        factory :creator_contacting_customers_email_info_opened do
          state { "opened" }
          opened_at { Time.current }
        end
      end
    end
  end
end
