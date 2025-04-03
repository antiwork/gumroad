# frozen_string_literal: true

FactoryBot.define do
  factory :product_file do
    association :link, factory: :product
    url { "https://s3.amazonaws.com/gumroad-specs/#{SecureRandom.hex}.pdf" }

    trait :analyze do
      after(:create) { |file| file.analyze }
    end

    factory :external_link do
      url { "https://www.gumroad.com" }
      filetype { "link" }
      filegroup { "url" }
    end

    factory :streamable_video do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/ScreenRecording.mov" }
      filetype { "mov" }
      filegroup { "video" }
    end

    factory :non_streamable_video do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/ScreenRecording.mpg" }
      filetype { "mpg" }
      filegroup { "url" }
    end

    factory :listenable_audio do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/magic.mp3" }
      filetype { "mp3" }
      filegroup { "audio" }
    end

    factory :non_listenable_audio do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/test-with-tags.aiff" }
      filetype { "aiff" }
      filegroup { "url" }
    end

    factory :readable_document, aliases: [:pdf_product_file] do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/billion-dollar-company-chapter-0.pdf" }
      filetype { "pdf" }
      filegroup { "document" }
    end

    factory :non_readable_document, aliases: [:epub_product_file] do
      url { "https://s3.amazonaws.com/gumroad-specs/specs/test.epub" }
      filetype { "epub" }
      filegroup { "epub_document" }
    end
  end
end
