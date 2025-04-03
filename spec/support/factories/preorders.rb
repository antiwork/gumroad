# frozen_string_literal: true

FactoryBot.define do
  factory :preorder do
    preorder_link
    seller { preorder_link.link.user }
    state { "in_progress" }
  end
end
