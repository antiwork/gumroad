# frozen_string_literal: true

FactoryBot.define do
  factory :marketing_action, class: "Marketing::Action" do
    user
    link { association(:product, user:) }
    channel { "x" }
    copy { "The Works of Edgar Gumstein: a decade of shack writing." }
  end
end
