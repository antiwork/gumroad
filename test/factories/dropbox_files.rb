# frozen_string_literal: true

FactoryBot.define do
  factory :dropbox_file do
    dropbox_url { "MyString" }
    state { "in_progress" }
  end
end
