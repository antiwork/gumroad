# frozen_string_literal: true

require("spec_helper")

describe("Product page previews", js: true, type: :system) do
  before do
    @product = create(:product, user: create(:user), custom_receipt: "<h1>Hello</h1>")
    create(:asset_preview, link: @product)
    create(:asset_preview, url: "https://www.youtube.com/watch?v=5Bcpj-q0Snc", link: @product)
    create(:asset_preview_mov, link: @product)
  end

  it "allows switching between multiple previews" do
    visit @product.long_url

    preview = find("[aria-label='Product preview']")

    preview.hover

    within preview do
      expect(page).to have_selector("img[src*='#{PUBLIC_STORAGE_S3_BUCKET}']")
      expect(page).to have_selector("iframe", visible: false)
      expect(page).to have_selector("video[src*='#{PUBLIC_STORAGE_S3_BUCKET}']", visible: false)
      expect(page).to have_button("Show next cover")
      expect(page).to have_tablist("Select a cover")
    end

    within preview do
      expect(page).to have_button("Show next cover")
      expect(page).to have_tablist("Select a cover")

      select_tab "Show cover 2"
      expect(page).to have_selector("img[src*='#{PUBLIC_STORAGE_S3_BUCKET}']", visible: false)
      expect(page).to have_selector("iframe")
      expect(page).to have_selector("video[src*='#{PUBLIC_STORAGE_S3_BUCKET}']", visible: false)

      click_on "Show next cover"
      expect(page).to have_selector("img[src*='#{PUBLIC_STORAGE_S3_BUCKET}']", visible: false)
      expect(page).to have_selector("iframe", visible: false)
      expect(page).to have_selector("video[src*='#{PUBLIC_STORAGE_S3_BUCKET}']")
    end
  end

  context "when the preview is oembed or a video" do
    it "hides the tablist" do
      visit @product.long_url
      preview = find("[aria-label='Product preview']")
      preview.hover
      within preview do
        expect(page).to have_selector("img[src*='#{PUBLIC_STORAGE_S3_BUCKET}']")
        expect(page).to have_tablist("Select a cover")
        click_on "Show next cover"
        expect(page).to have_selector("iframe[src*='https://www.youtube.com/embed/5Bcpj-q0Snc?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1']")
        expect(page).to_not have_tablist("Select a cover")
        click_on "Show next cover"
        expect(page).to have_selector("video[src*='#{PUBLIC_STORAGE_S3_BUCKET}']")
        expect(page).to_not have_tablist("Select a cover")
      end
    end
  end

  describe "scrolling between previews" do
    let(:product) { create(:product) }

    before do
      create_list(:asset_preview, 3, link: product)
    end

    it "allows swiping between image previews" do
      visit product.long_url

      previews = all("[role='tabpanel']")

      find("[aria-label='Product preview']").hover

      click_on "Show next cover"
      scroll_to previews[2]
      expect(page).to_not have_button("Show next cover")
      expect(page).to have_button("Show previous cover")

      click_on "Show previous cover"
      scroll_to previews[0]
      expect(page).to have_button("Show next cover")
      expect(page).to_not have_button("Show previous cover")
    end
  end
end
