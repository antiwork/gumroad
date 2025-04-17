# frozen_string_literal: true

FactoryBot.define do
  factory :video_file do
    url { "https://s3.amazonaws.com/gumroad-specs/specs/ScreenRecording.mov" }
    filetype { "mov" }
    user { create(:user) }
    record { user }
  end
end
