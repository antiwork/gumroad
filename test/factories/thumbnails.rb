# frozen_string_literal: true

FactoryBot.define do
  factory :thumbnail do
    product { create(:product) }
    before(:create) do |thumbnail|
      blob = ActiveStorage::Blob.create_and_upload!(io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
    end

    after(:create) do |thumbnail|
      thumbnail.file.analyze if thumbnail.file.attached?
    end
  end

  factory :unsplash_thumbnail, class: "Thumbnail" do
    product { create(:product) }
    unsplash_url { "https://images.unsplash.com/photo-1587502536575-6dfba0a6e017" }
  end
end
