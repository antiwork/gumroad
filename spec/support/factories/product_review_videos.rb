# frozen_string_literal: true

FactoryBot.define do
  factory :product_review_video do
    association :product_review

    approval_status { :pending_review }

    after(:build) do |video|
      video.video_file ||= build(:video_file, record: video)
    end
  end
end
