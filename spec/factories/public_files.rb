# frozen_string_literal: true

FactoryBot.define do
  factory :public_file do
    sequence(:original_file_name) { |n| "test-#{n}.mp3" }
    sequence(:display_name) { |n| "Test audio #{n}" }
    public_id { PublicFile.generate_public_id }
    resource { association :product }

    trait :with_audio do
      after(:build) do |public_file|
        public_file.file.attach(
          io: File.open(Rails.root.join("spec/support/fixtures/test.mp3")),
          filename: "test.mp3",
          content_type: "audio/mpeg"
        )
      end
    end
  end
end
