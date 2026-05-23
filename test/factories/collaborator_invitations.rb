# frozen_string_literal: true

FactoryBot.define do
  factory :collaborator_invitation do
    association :collaborator, factory: :collaborator
  end
end
