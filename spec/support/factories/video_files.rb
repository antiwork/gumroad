# frozen_string_literal: true

FactoryBot.define do
  factory :video_file do
    record { create(:user) }
    url { "https://s3.amazonaws.com/gumroad-specs/specs/ScreenRecording.mov" }
    filetype { "mov" }
  end
end
