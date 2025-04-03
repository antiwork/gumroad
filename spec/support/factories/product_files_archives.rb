# frozen_string_literal: true

FactoryBot.define do
  factory :product_files_archive do
    association :link, factory: :product
    after(:create) do |pfa|
      pfa.set_url_if_not_present
      pfa.save!
    end
  end

  factory :product_files_archive_without_url, class: ProductFilesArchive do
    association :link, factory: :product
  end
end
