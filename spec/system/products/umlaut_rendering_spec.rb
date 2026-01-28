# frozen_string_literal: true

require "spec_helper"

describe "Product Umlaut Character Rendering", type: :system, js: true do
  let(:seller) { create(:user) }
  let(:product_with_umlauts) do
    create(:product,
           user: seller,
           name: "Testing Umlaut: ö ò ö ö ö ö ö ö ö öüùüùùùùùùùùù",
           description: "<p>Hello i am testing the umlaut appearance.</p><p>Ä ö ò ö ö ö ö ö ö ö ö öüùüùùùùùùùùù</p><p>üüùüùüüùüùüùü</p><p>ú ù</p>")
  end

  before do
    visit product_with_umlauts.long_url
  end

  it "displays Umlaut characters correctly in product title" do
    expect(page).to have_css("h1[itemprop='name']", text: /Testing Umlaut/)
    expect(page).to have_css("h1[itemprop='name']", text: /ö/)
    expect(page).to have_css("h1[itemprop='name']", text: /ü/)
    expect(page).to have_css("h1[itemprop='name']", text: /ù/)
  end

  it "displays Umlaut characters correctly in product description" do
    expect(page).to have_content("Hello i am testing the umlaut appearance")
    expect(page).to have_content(/Ä/)
    expect(page).to have_content(/ú/)
  end

  it "renders characters without mojibake or boxes" do
    within("h1[itemprop='name']") do
      title_text = page.text
      expect(title_text).not_to include("�")
      expect(title_text).to match(/ö/)
      expect(title_text).to match(/ü/)
    end
  end
end
