# frozen_string_literal: true

require "spec_helper"

describe "Product page file summary", js: true, type: :system do
  it "summarizes the selected version's files without naming them" do
    product = create(:product)
    category = create(:variant_category, link: product)
    { "MP3" => ["mp3", 1.megabyte], "WAV" => ["wav", 30.megabytes] }.each do |name, (filetype, size)|
      version = create(:variant, variant_category: category, name:)
      2.times do |index|
        file = create(:product_file, link: product, display_name: "#{name} take #{index}")
        file.update_columns(filetype:, size:)
        version.product_files << file
      end
    end
    product.update!(has_same_rich_content_for_all_variants: false)

    visit product.long_url
    expect(page).to have_radio_button("WAV")
    expect(page).not_to have_selector("[role='note']")

    choose "WAV"
    expect(page).to have_selector("[role='note']", exact_text: "Includes: 2 files · WAV · 60.0 MB")

    choose "MP3"
    expect(page).to have_selector("[role='note']", exact_text: "Includes: 2 files · MP3 · 2.0 MB")
    expect(page.html).not_to include("MP3 take", "WAV take")
  end
end
