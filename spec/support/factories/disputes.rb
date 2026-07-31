# frozen_string_literal: true

FactoryBot.define do
  factory :dispute do
    purchase
    event_created_at { Time.current }
  end

  factory :dispute_on_charge, parent: :dispute do
    purchase { nil }
    charge
  end

  factory :dispute_formalized, parent: :dispute do
    reason { Dispute::REASON_FRAUDULENT }
    state { :formalized }
    formalized_at { Time.current }
    # A formalized dispute has normally finished its side effects; the migration backfilled every
    # dispute that predates the marker. Override with nil to model a formalization still in flight.
    formalized_side_effects_finished_at { Time.current }
  end

  factory :dispute_formalized_on_charge, parent: :dispute_on_charge do
    purchase { nil }
    charge do
      charge = create(:charge)
      charge.purchases << create(:purchase, email: "customer@example.com")
      charge.purchases << create(:purchase, email: "customer@example.com")
      charge.purchases << create(:purchase, email: "customer@example.com")
      charge
    end
    state { :formalized }
    formalized_at { Time.current }
  end
end
