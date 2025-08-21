# frozen_string_literal: true

require "spec_helper"

describe("Discover - Filtering scenarios", js: true, type: :system) do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    @audio_taxonomy = Taxonomy.find_by(slug: "audio")
    @wallpapers_taxonomy = Taxonomy.find_by(slug: "wallpapers", parent: Taxonomy.find_by(slug: "design"))

    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @png = Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png")
    seed_products
  end

  def seed_products
    travel_to(91.days.ago) do
      recurrence_price_values = [
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 10 } },
        { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 1 } }
      ]
      @similar_product_5 = create(:membership_product_with_preset_tiered_pricing,
                                  name: "product 5 (with tiers)",
                                  recurrence_price_values:,
                                  user: create(:compliant_user, name: "Gumstein VI"),
                                  taxonomy: @wallpapers_taxonomy)
    end
    travel_to(5.minutes.ago) do
      @product = create(:product, taxonomy: @audio_taxonomy, user: create(:compliant_user, name: "Gumstein"), name: "product 0")
    end
    travel_to(4.minutes.ago) do
      @similar_product_1 = create(:product, taxonomy: @audio_taxonomy, user: create(:compliant_user, name: "Gumstein II"), name: "product 1", preview: @png, price_cents: 200, discover_fee_per_thousand: 300)
    end
    travel_to(3.minutes.ago) do
      @similar_product_2 = create(:product, taxonomy: @audio_taxonomy, user: create(:compliant_user, name: "Gumstein III"), name: "product 2", preview: @png, price_cents: 300, discover_fee_per_thousand: 400)
    end
    travel_to(2.minutes.ago) do
      @similar_product_3 = create(:product, taxonomy: @audio_taxonomy, user: create(:compliant_user, name: "Gumstein IV"), name: "product 3", preview: @png, price_cents: 400)
    end
    travel_to(1.minute.ago) do
      @similar_product_4 = create(:product, taxonomy: @audio_taxonomy, user: create(:compliant_user, name: "Gumstein V"), name: "product 4", preview: @png, price_cents: 500)
    end

    create(:product_review, purchase: create(:purchase, email: "gumroaduser1@gmail.com", link: @similar_product_5), rating: 1)
    create(:product_review, purchase: create(:purchase, link: @similar_product_4))

    2.times do |i|
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @product), rating: 5)
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @similar_product_1), rating: 4)
    end

    3.times do |i|
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @product), rating: 5)
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @similar_product_2), rating: 3)
    end

    4.times do |i|
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @product), rating: 5)
      create(:product_review, purchase: create(:purchase, email: "gumroaduser#{i}@gmail.com", link: @similar_product_3), rating: 2)
    end

    create(:purchase, email: "gumroaduser1@gmail.com", link: @product)
    create(:purchase, email: "gumroaduser1@gmail.com", link: @similar_product_4)
    create(:purchase, email: @buyer.email, purchaser: @buyer, link: @product)

    index_model_records(Purchase)
    index_model_records(Link)
  end

  it "filters products by filetype" do
    product = create(:product, :recommendable, name: "product with a PDF", created_at: 1.minute.ago)
    create(:product_file, link: product)
    product2 = create(:product, :recommendable, name: "product with a MP3", created_at: 2.minutes.ago)
    create(:listenable_audio, link: product2)

    index_model_records(Purchase)
    index_model_records(Link)

    visit discover_url(host: discover_host)
    fill_in("Search products", with: "product\n")

    toggle_disclosure "Contains"

    check "pdf (1)"
    wait_for_ajax
    expect_product_cards_with_names("product with a PDF")

    check "mp3 (1)"
    wait_for_ajax
    expect_product_cards_with_names("product with a MP3", "product with a PDF")

    uncheck "pdf (1)"
    wait_for_ajax
    expect_product_cards_with_names("product with a MP3")

    uncheck "mp3 (1)"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, product, product2, @similar_product_5])

    visit discover_url(host: discover_host, query: "product", filetypes: "mp3,pdf")
    expect_product_cards_with_names("product with a MP3", "product with a PDF")

    select_disclosure "Contains" do
      expect(page).to have_checked_field("mp3")
      expect(page).to have_checked_field("pdf")
    end
  end

  it "filters products by tags" do
    @similar_product_2.tag!("tag1")
    @similar_product_2.tag!("tag2")
    @similar_product_3.tag!("tag2")

    index_model_records(Purchase)
    index_model_records(Link)

    visit discover_url(host: discover_host)
    fill_in("Search products", with: "product\n")
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, @similar_product_5])

    toggle_disclosure "Tags"

    check "tag1"
    expect_product_cards_in_order([@similar_product_2])

    check "tag2"
    expect_product_cards_in_order([@similar_product_3, @similar_product_2])

    uncheck "tag1"
    expect_product_cards_in_order([@similar_product_3, @similar_product_2])

    uncheck "tag2"
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, @similar_product_5])

    visit discover_url(host: discover_host, query: "product", tags: "tag1,tag2")
    expect_product_cards_in_order([@similar_product_3, @similar_product_2])
    select_disclosure "Tags" do
      expect(page).to have_checked_field("tag1")
      expect(page).to have_checked_field("tag2")
    end
  end

  it "sorts products" do
    visit discover_url(host: discover_host)
    fill_in("Search products", with: "product\n")
    wait_for_ajax

    select_disclosure "Sort by" do
      expect(page).to have_checked_field "Default"
    end
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, @similar_product_5])

    choose "Newest"
    wait_for_ajax
    expect_product_cards_in_order([@similar_product_4, @similar_product_3, @similar_product_2, @similar_product_1, @product, @similar_product_5])

    choose "Highest rated"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_1, @similar_product_2, @similar_product_3, @similar_product_4, @similar_product_5])

    choose "Most reviewed"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_1, @similar_product_4, @similar_product_5])

    choose "Price (Low to High)"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_5, @similar_product_1, @similar_product_2, @similar_product_3, @similar_product_4])

    choose "Price (High to Low)"
    wait_for_ajax
    expect_product_cards_in_order([@similar_product_4, @similar_product_3, @similar_product_2, @similar_product_1, @product, @similar_product_5])

    choose "Default"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, @similar_product_5])

    choose "Hot and new"
    wait_for_ajax
    expect_product_cards_in_order([@similar_product_3, @product, @similar_product_4, @similar_product_2, @similar_product_1])
  end

  it "filters products by price" do
    visit discover_url(host: discover_host)
    fill_in("Search products", with: "product\n")

    toggle_disclosure "Price"
    fill_in "Minimum price", with: "3"
    wait_for_ajax

    expect_product_cards_in_order([@similar_product_3, @similar_product_2, @similar_product_4, @similar_product_5])

    fill_in "Maximum price", with: "4"
    wait_for_ajax
    expect_product_cards_in_order([@similar_product_3, @similar_product_2])

    visit discover_url(host: discover_host, query: "product")
    toggle_disclosure "Price"
    fill_in "Maximum price", with: "4"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_1, @similar_product_5])

    fill_in "Maximum price", with: "0"
    wait_for_ajax
    expect(page).to have_content("No products found")
    expect(page).to have_product_card(count: 0)

    fill_in "Maximum price", with: "4"
    fill_in "Minimum price", with: "8"
    wait_for_ajax
    expect_alert_message("Please set the price minimum to be lower than the maximum.")
  end

  it "filters products by ratings" do
    visit discover_url(host: discover_host)
    fill_in("Search products", with: "product\n")

    expect(page).to have_product_card(count: 6)

    toggle_disclosure "Rating"

    # filter by 4 star + ratings
    choose "4 stars and up"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_1])

    # filter by 3 star + ratings
    choose "3 stars and up"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_2, @similar_product_1])

    # filter by 2 star + ratings
    choose "2 stars and up"
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_1])

    # filter by 1 star + ratings
    choose "1 star and up"
    wait_for_ajax

    expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1, @similar_product_5])
  end

  it "properly restores state and taxonomy category when pressing back" do
    visit discover_url(host: discover_host, query: "product")

    select_disclosure "Price" do
      fill_in "Maximum price", with: "3"
    end
    wait_for_ajax
    expect_product_cards_in_order([@product, @similar_product_2, @similar_product_1, @similar_product_5])

    find("[role=menuitem]", text: "Audio").hover
    click_on "All Audio"
    wait_for_ajax
    expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Audio")
    within_section "Featured products", section_element: :section do
      expect_product_cards_in_order([@product, @similar_product_3, @similar_product_2, @similar_product_4, @similar_product_1])
    end

    select_disclosure "Price" do
      fill_in "Maximum price", with: "2"
    end
    wait_for_ajax
    within_section "On the market" do
      expect_product_cards_in_order([@product, @similar_product_1])
    end

    page.go_back
    wait_for_ajax
    select_disclosure "Price" do
      expect(page).to have_field "Maximum price", with: ""
    end
    expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Audio")

    page.go_back
    wait_for_ajax
    select_disclosure "Price" do
      expect(page).to have_field "Maximum price", with: "3"
    end
    expect_product_cards_in_order([@product, @similar_product_2, @similar_product_1, @similar_product_5])

    page.go_back
    wait_for_ajax
    select_disclosure "Price" do
      expect(page).to have_field "Maximum price", with: ""
    end
  end

  it "filters from url params and updates UI" do
    visit discover_url(host: discover_host, query: "product", rating: "3", min_price: "2", max_price: "4", sort: "highest_rated")
    wait_for_ajax
    expect_product_cards_in_order([@similar_product_1, @similar_product_2])
    select_disclosure "Sort by" do
      expect(page).to have_checked_field("Highest rated")
    end
    select_disclosure "Rating" do
      expect(page).to have_checked_field("3 stars and up")
    end
  end

  describe "nsfw filter" do
    let(:software_taxonomy) { Taxonomy.find_by(slug: "software-development") }
    let!(:sfw_product) { create(:product, :recommendable, name: "sfw product", taxonomy: software_taxonomy) }
    let!(:adult_product) { create(:product, :recommendable, name: "adult product", taxonomy: software_taxonomy, is_adult: true) }

    before do
      index_model_records(Purchase)
      index_model_records(Link)
    end

    context "when show_nsfw_products flag is off" do
      let(:user) { create(:user, show_nsfw_products: false) }

      it "hides adult products" do
        login_as(user)
        visit "#{discover_host}/software-development?sort=featured"

        within_section "On the market" do
          expect_product_cards_with_names("sfw product")
        end
        expect(page).not_to have_product_card(text: "adult product")
      end
    end

    context "when show_nsfw_products flag is on" do
      let(:user) { create(:user, show_nsfw_products: true) }

      it "shows adult products" do
        login_as(user)
        visit "#{discover_host}/software-development?sort=featured"

        within_section "On the market" do
          expect_product_cards_with_names("sfw product", "adult product")
        end
      end
    end
  end

  describe "taxonomy", :elasticsearch_wait_for_refresh do
    before do
      csharp_taxonomy = Taxonomy.find_by(slug: "c-sharp", parent: Taxonomy.find_by(slug: "programming", parent: Taxonomy.find_by(slug: "software-development")))
      4.times do |i|
        product = create(:product, user: create(:compliant_user), name: "C# #{i}", price_cents: 100 * i, taxonomy: csharp_taxonomy)
        create(:product_review, purchase: create(:purchase, email: "taxonomy#{i}@gmail.com", link: product), rating: i + 1)
      end

      visit "#{discover_host}/software-development/programming/c-sharp?query=c&sort=featured"
    end

    it "filters results by taxonomy" do
      expect_product_cards_with_names("C# 0", "C# 1", "C# 2", "C# 3")
    end

    it "correctly handles the search filters" do
      expect(page).to have_product_card(count: 4)

      toggle_disclosure "Price"
      fill_in("Maximum price", with: 2)
      wait_for_ajax
      expect_product_cards_with_names("C# 0", "C# 1", "C# 2")

      fill_in("Minimum price", with: 1)
      wait_for_ajax
      expect_product_cards_with_names("C# 1", "C# 2")

      click_on("Clear")
      wait_for_ajax
      expect(page).to have_product_card(count: 4)

      toggle_disclosure "Rating"
      choose("3 stars and up")
      wait_for_ajax
      expect_product_cards_with_names("C# 2", "C# 3")
    end

    it "correctly handles the search queries" do
      expect(page).to have_product_card(count: 4)

      fill_in("Search products", with: "C# 0\n")
      wait_for_ajax
      expect_product_cards_with_names("C# 0")

      fill_in("Search products", with: "product 0\n")
      wait_for_ajax
      expect(page).to_not have_product_card
    end
  end

  context "when having many active search filters" do
    it "has the tag as content title" do
      visit discover_url(host: discover_host, tags: "nevernever", rating: "4", min_price: "9999", max_price: "99999", sort: "most_reviewed", filetypes: "ftx")

      select_disclosure "Tags" do
        expect(page).to have_content("nevernever (0)")
      end
      select_disclosure "Contains" do
        expect(page).to have_content("ftx (0)")
      end
    end

    it "clears filters, but not category, when filling search box" do
      visit "#{discover_host}/design/wallpapers?max_price=99999&min_price=9999&rating=4&sort=most_reviewed&filetypes=ftx&tags=never"

      fill_in "Search products", with: "product"
      find_field("Search products").native.send_keys(:return)

      expect_product_cards_with_names("product 5 (with tiers)")
    end

    it "clears filters when changing categories" do
      visit discover_url(host: discover_host, tags: "never", rating: "4", min_price: "9999", max_price: "99999", sort: "most_reviewed", filetypes: "ftx")

      within "[role=menubar]" do
        click_on "Audio"
      end

      fill_in "Search products", with: "product"
      find_field("Search products").native.send_keys(:return)

      expect_product_cards_with_names("product 0", "product 1", "product 2", "product 3", "product 4")
    end
  end
end
