# frozen_string_literal: true

FactoryBot.define do
  factory :asset_preview do
    association :link, factory: :product

    transient do
      attach { true }
    end

    before(:create) do |preview, evaluator|
      preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png") if evaluator.attach
    end

    factory :asset_preview_mov do
      before(:create) do |preview, evaluator|
        preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "thing.mov"), "video/quicktime") if evaluator.attach
      end
    end

    factory :asset_preview_jpg do
      before(:create) do |preview, evaluator|
        preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "test-small.jpg"), "image/jpeg") if evaluator.attach
      end
    end

    factory :asset_preview_gif do
      before(:create) do |preview, evaluator|
        preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "sample.gif"), "image/gif") if evaluator.attach
      end
    end

    factory :asset_preview_youtube do
      attach { false }
      oembed do
        {
          "html" =>
            "<iframe width=\"356\" height=\"200\" src=\"https://www.youtube.com/embed/qKebcV1jv3A?feature=oembed&showinfo=0&controls=0&rel=0\" frameborder=\"0\" allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture\" allowfullscreen></iframe>",
          "info" =>
            {
              "height" => 200,
              "width" => 356,
              "thumbnail_url" => "https://i.ytimg.com/vi/qKebcV1jv3A/hqdefault.jpg"
            }
        }
      end
    end

    after(:create) do |preview|
      preview.file.analyze if preview.file.attached?
    end
  end
end
