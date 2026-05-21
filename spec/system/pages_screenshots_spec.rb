# frozen_string_literal: true

require "spec_helper"

describe "Pages screenshots", type: :feature, js: true do
  let(:seller) { create(:named_seller) }

  before do
    Feature.activate(:pages)
    seller.update!(username: "testcreator")
    login_as(seller)
  end

  it "captures pages index (empty state)" do
    visit pages_path
    save_screenshot("qa-media/pr-5171-pages-index-empty.png", full: true)
  end

  it "captures pages new" do
    create(:product, user: seller, name: "Web Dev Course", price_cents: 4900)
    visit new_page_path
    save_screenshot("qa-media/pr-5171-pages-new.png", full: true)
  end

  it "captures pages index with pages" do
    seller.pages.create!(title: "My Landing Page", slug: "my-landing-page")
    seller.pages.create!(
      title: "Product Showcase",
      slug: "product-showcase",
      published: true,
      published_at: Time.current,
      html_content: "<div>Test</div>",
    )
    visit pages_path
    save_screenshot("qa-media/pr-5171-pages-index-list.png", full: true)
  end

  it "captures page editor" do
    page_record = seller.pages.create!(
      title: "Product Showcase",
      slug: "product-showcase",
      html_content: '<div class="min-h-screen bg-gradient-to-b from-gray-900 to-black text-white"><section class="max-w-4xl mx-auto px-6 py-24 text-center"><h1 class="text-6xl font-bold mb-6">Master Web Development</h1><p class="text-xl text-gray-300 mb-12">Learn the skills that will change your career.</p><a href="#" class="bg-indigo-600 hover:bg-indigo-700 text-white px-8 py-4 rounded-lg text-lg font-semibold">Get Started - $49</a></section></div>',
    )
    visit edit_page_path(page_record.slug)
    sleep 2 # let iframe render
    save_screenshot("qa-media/pr-5171-pages-editor.png", full: true)
  end
end
