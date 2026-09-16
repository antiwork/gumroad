# frozen_string_literal: true

FactoryBot.define do
  factory :marketing_holdout_assignment, class: "Marketing::HoldoutAssignment" do
    user
    prior_sales_bucket { "zero" }
    marketing_holdout { false }
    marketing_holdout_assigned_at { Time.current }
  end
end
