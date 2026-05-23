# frozen_string_literal: true

FactoryBot.define do
  factory :charge_event, class: ChargeEvent do
    skip_create # ChargeEvent is not an ActiveRecord object; does not define "save!"

    charge_id { "charge-#{Random.rand}" }
    created_at { DateTime.current }
    comment { "charge succeeded" }
    type { ChargeEvent::TYPE_INFORMATIONAL }

    factory :charge_event_dispute_formalized do
      type { ChargeEvent::TYPE_DISPUTE_FORMALIZED }
      comment { "charge dispute formalized" }
      flow_of_funds do
        FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -100)
      end
    end

    factory :charge_event_dispute_won do
      type { ChargeEvent::TYPE_DISPUTE_WON }
      comment { "charge dispute closed" }
      flow_of_funds do
        FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100)
      end
    end

    factory :charge_event_dispute_lost do
      type { ChargeEvent::TYPE_DISPUTE_LOST }
      comment { "charge.dispute.closed" }
    end

    factory :charge_event_settlement_declined do
      type { ChargeEvent::TYPE_SETTLEMENT_DECLINED }
      comment { "settlement declined" }
    end

    factory :charge_event_informational do
      type { ChargeEvent::TYPE_INFORMATIONAL }
      comment { "hello!!!" }
    end

    factory :charge_event_charge_succeeded do
      type { ChargeEvent::TYPE_CHARGE_SUCCEEDED }
      comment { "charge succeeded" }
      flow_of_funds do
        FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 100)
      end
    end

    factory :charge_event_payment_failed do
      type { ChargeEvent::TYPE_PAYMENT_INTENT_FAILED }
      comment { "payment failed" }
    end
  end
end
