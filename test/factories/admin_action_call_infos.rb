# frozen_string_literal: true

FactoryBot.define do
  factory :admin_action_call_info do
    controller_name { "Admin::UsersController" }
    action_name { "show" }
    call_count { 0 }
  end
end
