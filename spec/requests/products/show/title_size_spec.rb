# frozen_string_literal: true

require "spec_helper"

# The repo's :mobile_chrome driver names a device ("iPhone 8") that current Chrome builds reject, so
# this spec registers its own phone-width driver. The title steps down below the sm breakpoint (640px).
Capybara.register_driver :title_size_phone_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  docker_browser_args.each { |arg| options.args << arg } if ENV["IN_DOCKER"] == "true"
  options.add_emulation(device_metrics: { width: 375, height: 800, pixelRatio: 2, touch: true })
  options.add_preference("intl.accept_languages", "en-US")
  test_host_resolver_args.each { |arg| options.args << arg }

  # Same WebDriver timeouts as the shared drivers in spec/support/capybara_driver.rb.
  http_client = Selenium::WebDriver::Remote::Http::Default.new(open_timeout: 120, read_timeout: 120)

  Capybara::Selenium::Driver.new(app, browser: :chrome, http_client:, options:)
end

describe "Product title size", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:long_name) { "The Complete Illustrated Guide to Hand Lettering, Brush Pens, Watercolor Washes and Greeting Cards" }
  let(:product) { create(:product, user: seller, name: long_name) }

  def title_font_size
    page.find("h1[itemprop=name]").native.css_value("font-size")
  end

  it "renders a 32px title on desktop when the title is long" do
    visit short_link_path(product)

    expect(title_font_size).to eq("32px")
  end

  it "keeps the stock 40px title when the title is short" do
    visit short_link_path(create(:product, user: seller, name: "Hand lettering"))

    expect(title_font_size).to eq("40px")
  end

  it "keeps the featured product on a profile at the stock size" do
    section = create(:seller_profile_featured_product_section, seller:, header: "Featured", featured_product_id: product.id)
    seller.seller_profile.update!(json_data: { tabs: [{ name: "Tab", sections: [section.id] }] })

    visit seller.subdomain_with_protocol

    expect(title_font_size).to eq("40px")
  end

  describe "on a phone" do
    before { driven_by :title_size_phone_chrome }

    it "renders a 24px title when the title is long" do
      visit short_link_path(product)

      expect(page.evaluate_script("window.innerWidth")).to eq(375)
      expect(title_font_size).to eq("24px")
    end

    it "keeps the stock 40px title when the title is short" do
      visit short_link_path(create(:product, user: seller, name: "Hand lettering"))

      expect(page.evaluate_script("window.innerWidth")).to eq(375)
      expect(title_font_size).to eq("40px")
    end
  end
end
