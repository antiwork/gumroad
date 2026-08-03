# frozen_string_literal: true
# THROWAWAY — capture-only, never commit.

require "spec_helper"

SHOT_DIR = "/tmp/gp1796-shots".freeze

describe("PR #6946 VRChat facets QA capture", type: :system, js: true,
         mobile_view: ENV.fetch("SHOT_TAG", "").start_with?("mobile")) do
  let(:tag) { ENV.fetch("SHOT_TAG", "desktop") }

  before do
    load Rails.root.join("db/seeds/010_development_staging_test/taxonomy_create.rb")
    Onetime::SeedTaxonomyAttributes.process(dry_run: false)
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_merchant_id = "acct_qagp1796"
      ma.charge_processor_alive_at = Time.current
    end

    if ENV["SHOT_THEME"] == "light"
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia",
        features: [{ name: "prefers-color-scheme", value: "light" }]
      )
    end
  end

  def shoot(name)
    FileUtils.mkdir_p(SHOT_DIR)
    path = File.join(SHOT_DIR, "#{tag}-#{name}.png")
    page.save_screenshot(path)
    puts "SHOT #{path} innerWidth=#{page.evaluate_script('window.innerWidth')}"
  end

  def seed_product(taxonomy_path:, values:, permalink:, name:)
    taxonomy = TaxonomyAttributeDefinitions.taxonomy_for(taxonomy_path)
    seller = create(:user, user_risk_state: "compliant")
    link = create(:product, user: seller, name:, taxonomy:,
                             display_product_reviews: true)
    link.save_taxonomy_attribute_values(values)
    buyer = create(:user)
    create(:purchase, link:, email: buyer.email)
    link.reload
    puts "seed_product #{link.unique_permalink}: recommendable?=#{link.recommendable?} reasons=#{link.recommendable_reasons.inspect}"
    link.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!
    link
  end

  it "captures the Discover facet sidebar for 3d/avatars" do
    link = seed_product(
      taxonomy_path: "3d/avatars",
      permalink: "gp1796av#{tag}",
      name: "QA VRChat Avatar (3D facets demo)",
      values: {
        "item_type" => "Full avatar",
        "platform" => "PC and Quest",
        "performance_rank" => "Excellent",
        "rigged" => true,
        "license" => "Commercial"
      }
    )
    sleep 1 # ES refresh
    visit "/discover?taxonomy=3d/avatars"
    expect(page).to have_text("On the market", wait: 20)
    expect(page).to have_text(link.name, wait: 20)

    %w[Item\ type Platform Performance\ rank Rigged License].each do |label|
      summary = page.all("summary", text: label, wait: 5).first
      summary&.click
    end
    sleep 0.5
    shoot("discover-avatars-facets")
  end

  it "captures the Discover facet sidebar for 3d/vrchat" do
    link = seed_product(
      taxonomy_path: "3d/vrchat",
      permalink: "gp1796vr#{tag}",
      name: "QA VRChat World Prop (3D facets demo)",
      values: {
        "item_type" => "Prop / world asset",
        "platform" => "PC",
        "performance_rank" => "Good",
        "rigged" => false,
        "license" => "Personal"
      }
    )
    sleep 1
    visit "/discover?taxonomy=3d/vrchat"
    expect(page).to have_text("On the market", wait: 20)
    expect(page).to have_text(link.name, wait: 20)

    %w[Item\ type Platform Performance\ rank Rigged License].each do |label|
      summary = page.all("summary", text: label, wait: 5).first
      summary&.click
    end
    sleep 0.5
    shoot("discover-vrchat-facets")
  end

  it "captures the product editor Share tab structured attribute inputs" do
    link = seed_product(
      taxonomy_path: "3d/avatars",
      permalink: "gp1796ed#{tag}",
      name: "QA VRChat Avatar Editor Demo",
      values: {
        "item_type" => "Full avatar",
        "platform" => "PC and Quest",
        "performance_rank" => "Excellent",
        "rigged" => true,
        "license" => "Commercial"
      }
    )
    seller = link.user
    seller.update!(password: "secret123456", password_confirmation: "secret123456") rescue nil
    seller.confirm unless seller.confirmed?
    visit "/login"
    fill_in "Email", with: seller.email
    fill_in "Password", with: "secret123456"
    click_button "Login"
    expect(page).to have_current_path(/\A(?!\/login)/, wait: 20)

    visit "/products/#{link.unique_permalink}/edit"
    expect(page).to have_text("Product", wait: 20)
    first(:link, "Share").click
    expect(page).to have_text("Item type", wait: 20)
    sleep 0.5
    shoot("editor-share-tab")
  end
end
