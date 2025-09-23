# frozen_string_literal: true

require "spec_helper"

describe("Discover", js: true, type: :system) do
  include StripeMerchantAccountHelper

  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @png = Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png")
  end

  let!(:three_d_taxonomy) { Taxonomy.find_by(slug: "3d") }
  let!(:design_taxonomy) { Taxonomy.find_by(slug: "design") }
  let!(:films_taxonomy) { Taxonomy.find_by(slug: "films") }
  let!(:software_development_taxonomy) { Taxonomy.find_by(slug: "software-development") }
  let!(:programming_taxonomy) { Taxonomy.find_by(slug: "programming", parent: software_development_taxonomy) }
  let!(:csharp_taxonomy) { Taxonomy.find_by(slug: "c-sharp", parent: programming_taxonomy) }

  def seed_products
    travel_to(5.seconds.ago) do
      @product = create(:product, user: create(:compliant_user, name: "Gumstein"), name: "product 0", taxonomy: three_d_taxonomy)
    end
    travel_to(4.seconds.ago) do
      @similar_product_1 = create(:product, user: create(:compliant_user, name: "Gumstein II"), name: "product 1", preview: @png, price_cents: 200, taxonomy: three_d_taxonomy)
    end
    travel_to(3.seconds.ago) do
      @similar_product_2 = create(:product, user: create(:compliant_user, name: "Gumstein III"), name: "product 2", preview: @png, price_cents: 300, taxonomy: three_d_taxonomy, created_at: 100.days.ago)
    end
    travel_to(2.seconds.ago) do
      @similar_product_3 = create(:product, user: create(:compliant_user, name: "Gumstein IV"), name: "product 3", preview: @png, price_cents: 400, taxonomy: three_d_taxonomy)
    end
    travel_to(1.second.ago) do
      @similar_product_4 = create(:product, user: create(:compliant_user, name: "Gumstein V"), name: "product 4", preview: @png, price_cents: 500, taxonomy: three_d_taxonomy)
    end

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

  describe "recommended products" do
    before do
      seed_products
    end

    context "when products are re-categorised" do
      before do
        @similar_product_1.update_attribute(:taxonomy, films_taxonomy)
        Link.import(refresh: true, force: true)
        visit "#{discover_host}/#{films_taxonomy.slug}"
      end

      it "shows category and top products in the new taxonomy based section" do
        within_section "Featured products", section_element: :section do
          expect(page).to have_product_card(count: 1)
          find_product_card(@similar_product_1).click
        end
        wait_for_ajax
        expect(page).to have_current_path(/^\/l\/#{@similar_product_1.unique_permalink}\?layout=discover&recommended_by=discover/)
      end
    end

    describe "category and tags" do
      before do
        @similar_product_1.update_attribute(:taxonomy, design_taxonomy)
        @similar_product_3.update_attribute(:taxonomy, design_taxonomy)
        @similar_product_1.tag!("action")
        @similar_product_2.tag!("action")

        login_as @buyer
        Link.import(refresh: true, force: true)
      end

      it "filters products when category and tag is changed" do
        @similar_product_3.tag!("multi word tag")
        @similar_product_3.tag!("another tag")
        Link.import(refresh: true, force: true)

        visit discover_url(host: discover_host, query: "gumstein")
        wait_for_ajax

        expect(page).to have_product_card(count: 5)

        toggle_disclosure "Tags"

        # test single word term
        check "action (2)"
        wait_for_ajax
        expect(page).to have_product_card(count: 2)

        uncheck "action (2)"
        wait_for_ajax
        expect(page).to have_product_card(count: 5)

        within "[role=menubar]" do
          click_on "Design"
        end

        # test multi word term
        check "multi word tag (1)"
        wait_for_ajax
        within_section "On the market" do
          expect(page).to have_product_card(count: 1)
        end

        # test many multi word tags
        check "another tag (1)"
        wait_for_ajax
        within_section "On the market" do
          expect(page).to have_product_card(count: 1)
        end

        uncheck "another tag (1)"
        wait_for_ajax
        uncheck "multi word tag (1)"

        within_section "On the market" do
          expect(page).to have_product_card(count: 2)
        end
        check "action (1)"

        within_section "On the market" do
          expect(page).to have_product_card(count: 1)
        end
      end

      it "sets the tags, and search query based on the URL and displays the correct results" do
        Link.__elasticsearch__.create_index!(force: true)
        @product.tag!("action")
        @product.tag!("book")
        @product.update_attribute(:taxonomy, films_taxonomy)
        @product.__elasticsearch__.index_document
        Link.__elasticsearch__.refresh_index!

        visit discover_url(host: discover_host, tags: "action,book", query: @product.name.split(" ")[0])
        wait_for_ajax

        expect(page).to have_product_card(count: 1)
        select_disclosure "Tags" do
          expect(page).to have_checked_field("book (1)")
          expect(page).to have_checked_field("action (1)")
        end
      end
    end
  end

  describe "recommended wishlists" do
    let!(:wishlists) { 4.times.map { |i| create(:wishlist, name: "My Wishlist #{i}", recent_follower_count: 10 - i) } }

    before do
      seed_products
      wishlists.each { create(:wishlist_product, wishlist: _1, product: @similar_product_1) }
    end

    it "displays top wishlists when there are no recommended products" do
      login_as @buyer
      visit discover_url(host: discover_host)
      wait_for_ajax

      expect(page).not_to have_text("Recommended")
      expect(page).to have_text("Featured products")

      within_section "Wishlists you might like", section_element: :section do
        expect_product_cards_in_order(wishlists)
      end

      click_on wishlists.first.name
      click_on @similar_product_1.name
      add_to_cart(@similar_product_1)
      check_out(@similar_product_1, email: @buyer.email, logged_in_user: @buyer)

      expect(Purchase.last).to have_attributes(
        recommended_by: RecommendationType::GUMROAD_DISCOVER_WISHLIST_RECOMMENDATION,
        affiliate: wishlists.first.user.global_affiliate,
        fee_cents: 60,
        affiliate_credit_cents: 14,
      )
    end

    it "recommends wishlists when there are recommended products" do
      create(:purchase, purchaser: @buyer, link: @product)
      create(:sales_related_products_info, smaller_product: @product, larger_product: @similar_product_2, sales_count: 1)
      rebuild_srpis_cache

      related_wishlist = create(:wishlist, name: "Related Wishlist", recent_follower_count: 0)
      create(:wishlist_product, wishlist: related_wishlist, product: @similar_product_2)

      login_as @buyer
      visit discover_url(host: discover_host)
      wait_for_ajax

      within_section "Wishlists you might like", section_element: :section do
        expect_product_cards_in_order([related_wishlist, *wishlists.first(3)])
      end
    end
  end

  describe "category pages" do
    before do
      seed_products
      index_model_records(Link)
    end

    it "displays the category page" do
      create(:wishlist_product, wishlist: create(:wishlist, name: "3D wishlist"), product: @similar_product_1)

      visit "#{discover_host}/3d"

      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "3D")

      within_section "Featured products", section_element: :section do
        expect(page).to have_product_card(count: 5)
      end

      within_section "Wishlists for 3D", section_element: :section do
        expect(page).to have_product_card(count: 1)
      end

      within_section "On the market" do
        expect(page).to have_tab_button("Trending", open: true)
        find(:tab_button, "Hot & New", open: false).click
      end

      expect(page).not_to have_section("On the market")
      within_section "Hot and new products" do
        expect(page).to have_tab_button("Trending", open: false)
        expect(page).to have_tab_button("Hot & New", open: true)

        find(:tab_button, "Best Sellers", open: false).click
      end

      expect(page).not_to have_section("Hot and new products")
      within_section "Best selling products" do
        expect(page).to have_tab_button("Trending", open: false)
        expect(page).to have_tab_button("Hot & New", open: false)
        expect(page).to have_tab_button("Best Sellers", open: true)
      end
    end

    it "applies search filters from the URL" do
      visit "#{discover_host}/3d?sort=hot_and_new&max_price=10"

      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "3D")
      within_section "Hot and new products" do
        expect(page).to have_tab_button("Trending", open: false)
        expect(page).to have_tab_button("Hot & New", open: true)
        select_disclosure "Price" do
          expect(page).to have_field("Maximum price", with: "10")
        end
      end
    end

    it "excludes recommended products from the main list" do
      create_list(:product, 5, :recommendable, user: create(:compliant_user), taxonomy: three_d_taxonomy)
      index_model_records(Link)

      visit "#{discover_host}/3d"

      within_section "Featured products", section_element: :section do
        expect(page).to have_product_card(count: 8)
      end

      within_section "On the market" do
        expect(page).to have_product_card(count: 2)
      end

      # Should also work with client-side navigation
      visit "#{discover_host}/discover"
      within "[role=menubar]" do
        find("[role=menuitem]", text: "3D").hover
        click_on "All 3D"
      end

      within_section "Featured products", section_element: :section do
        expect(page).to have_product_card(count: 8)
      end

      within_section "On the market" do
        expect(page).to have_product_card(count: 2)
      end
    end
  end

  describe "pagination" do
    before do
      creator = create(:recommendable_user)
      create_list(:product, 72, :recommendable, user: creator, taxonomy: films_taxonomy) do |product, index|
        product.name = "product #{index + 1}"
        product.price_cents = index * 100
        product.save!
      end
      allow_any_instance_of(Link).to receive(:reviews_count).and_return(1)
      Link.import(refresh: true, force: true)
    end

    it "loads more results when clicking load more" do
      visit "#{discover_host}/films?sort=price_asc"
      within_section "On the market" do
        expect(page).to have_product_card(count: 36)
        expect(page).to_not have_product_card(text: "product 37")
        expect(page).to_not have_product_card(text: "product 38")
        expect(page).to_not have_product_card(text: "product 39")
        expect(page).to_not have_product_card(text: "product 40")

        click_button "Load more"
        wait_for_ajax
        expect(page).to have_product_card(count: 45)
        expect(page).to have_product_card(text: "product 37")
        expect(page).to have_product_card(text: "product 38")
        expect(page).to have_product_card(text: "product 44")
        expect(page).to have_product_card(text: "product 45")
        expect(page).to_not have_product_card(text: "product 46")

        click_button "Load more"
        wait_for_ajax
        expect(page).to have_product_card(count: 54)
        expect(page).to have_product_card(text: "product 46")
        expect(page).to have_product_card(text: "product 54")
        expect(page).to_not have_product_card(text: "product 55")
      end
    end

    it "offsets results to account for featured products" do
      visit "#{discover_host}/films"

      within_section "Featured products", section_element: :section do
        expect(page).to have_product_card(count: 8)
      end

      within_section "On the market" do
        expect(page).to have_product_card(count: 36)
      end
    end
  end

  it "displays a link to the user's profile page with the recommended_by query parameter" do
    Link.__elasticsearch__.create_index!(force: true)
    product = create(:product, name: "Nothing but pine martens", price_cents: 3378, user: create(:compliant_user, name: "Sam Smith", username: "sam"))
    allow(product).to receive(:recommendable?).and_return(true)
    allow(product).to receive(:reviews_count).and_return(1)
    product.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!

    visit discover_url(host: discover_host)

    fill_in "Search products", with: "pine martens\n"

    expect_product_cards_in_order([product])
    expect(page).to have_link("Sam Smith", href: "http://sam.test.gumroad.com:31337?recommended_by=search")
    find_product_card(product).click
    expect(page).to have_current_path(/^\/l\/#{product.unique_permalink}\?layout=discover&recommended_by=search/)
    expect(page).to have_link("Sam Smith", href: "http://sam.test.gumroad.com:31337/?recommended_by=search")

    # Clicking the logo should take you back to Discover home page.
    click_on "Gumroad"
    expect(page).to have_text("On the market")
  end

  it "displays thumbnail in preview if available" do
    Link.__elasticsearch__.create_index!(force: true)
    product = create(:product, name: "Nothing but pine martens", price_cents: 3378, user: create(:compliant_user, name: "Sam Smith", username: "sam"))

    create(:thumbnail, product:)
    product.reload

    allow(product).to receive(:recommendable?).and_return(true)
    allow(product).to receive(:reviews_count).and_return(1)
    product.__elasticsearch__.index_document
    Link.__elasticsearch__.refresh_index!

    visit discover_url(host: discover_host)

    fill_in "Search products", with: "pine martens\n"

    expect_product_cards_in_order([product])

    within find_product_card(product) do
      expect(find("figure")).to have_image(src: product.thumbnail.url)
    end
  end

  describe "affiliate cookies" do
    it "sets the global affiliate cookie if affiliate_id query param is present" do
      affiliate = create(:user).global_affiliate
      visit discover_url(host: discover_host, affiliate_id: affiliate.external_id_numeric)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).to be_present
    end

    it "sets the direct affiliate cookie if affiliate_id query param is present" do
      affiliate = create(:direct_affiliate)
      visit discover_url(host: discover_host, affiliate_id: affiliate.external_id_numeric)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).to be_present
    end
  end

  describe "taxonomy" do
    before do
      seed_products

      @similar_product_1.update_attribute(:taxonomy, software_development_taxonomy)
      @similar_product_2.update_attribute(:taxonomy, programming_taxonomy)
      @similar_product_2.tag!("my-tag")
      @similar_product_3.update_attribute(:taxonomy, csharp_taxonomy)
      @product.update_attribute(:taxonomy, csharp_taxonomy)
      @product.tag!("my-tag")
      @product.tag!("othertag")

      index_model_records(Link)
    end

    it "shows tags and taxonomy in title, plus breadcrumbs in page" do
      visit "#{discover_host}/software-development/programming/c-sharp?tags=some-tag"

      expect(page).to have_title("some tag | Software Development » Programming » C# | Gumroad")
      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Software Development\nProgramming\nC#")
    end

    it "shows breadcrumbs with taxonomy links and handles back and forward buttons" do
      visit "#{discover_host}/software-development/programming/c-sharp?sort=featured"

      expect(page).to have_title("Software Development » Programming » C# | Gumroad")
      within_section "Featured products", section_element: :section do
        expect_product_cards_with_names("product 0", "product 3")
      end

      select_disclosure "Tags" do
        check "my-tag (1)"
      end
      wait_for_ajax
      expect(page).to have_current_path("/software-development/programming/c-sharp?sort=featured&tags=my-tag")
      expect(page).to have_title("my tag | Software Development » Programming » C# | Gumroad")
      within_section "On the market" do
        expect_product_cards_with_names("product 0")
      end

      within("[role=navigation][aria-label='Breadcrumbs']") do
        click_on "Programming"
      end
      expect(page).to have_current_path("/software-development/programming")
      expect(page).to have_title("Software Development » Programming | Gumroad")
      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Software Development\nProgramming")

      within_section "Featured products", section_element: :section do
        expect_product_cards_with_names("product 0", "product 2", "product 3")
      end
      wait_for_ajax

      page.go_back
      wait_for_ajax
      expect(page).to have_current_path("/software-development/programming/c-sharp?sort=featured&tags=my-tag")

      page.go_back
      wait_for_ajax
      expect(page).to have_current_path("/software-development/programming/c-sharp?sort=featured")
      expect(page).to have_title("Software Development » Programming » C# | Gumroad")
      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Software Development\nProgramming\nC#")
      within_section "Featured products", section_element: :section do
        expect_product_cards_with_names("product 0", "product 3")
      end

      page.go_forward
      wait_for_ajax
      page.go_forward
      wait_for_ajax
      expect(page).to have_current_path("/software-development/programming")
      expect(page).to have_title("Software Development » Programming | Gumroad")
      expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Software Development\nProgramming")
      within_section "Featured products", section_element: :section do
        expect_product_cards_with_names("product 0", "product 2", "product 3")
      end
    end

    it "sets the affiliate cookie" do
      affiliate = create(:direct_affiliate)
      visit "#{discover_host}/software-development/programming/c-sharp?tags=some-tag&#{Affiliate::SHORT_QUERY_PARAM}=#{affiliate.external_id_numeric}"
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).to be_present
    end

    describe "discover nav" do
      it "sets aria-current on the active category" do
        visit "#{discover_host}/business-and-money"

        within "[role=menubar]" do
          find("[role=menuitem]", text: "Business & Money").hover
          click_on "All Business & Money"

          expect(page).to have_selector("[aria-current=true]", text: "Business & Money")
        end
      end

      it "changes current selected taxonomy category via nav, and sets aria-current is its top-level category" do
        visit discover_url(host: discover_host)

        find("[role=menuitem]", text: "Business & Money").hover
        click_on "Entrepreneurship"
        click_on "Courses"

        expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Business & Money\nEntrepreneurship\nCourses")
        within "[role=menubar]" do
          expect(page).to have_selector("[aria-current=true]", text: "Business & Money")
        end
      end

      it "allows returning to previous menu using 'Back' and selection of non-leaf categories via 'All'" do
        visit discover_url(host: discover_host)

        find("[role=menuitem]", text: "Business & Money").hover
        click_on "Entrepreneurship"
        click_on "Back"
        click_on "All Business & Money"

        expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Business & Money")
      end

      it "places categories that didn't fit the screen under 'More', which becomes aria-current if one of those categories is selected" do
        visit discover_url(host: discover_host)

        find("[role=menuitem]", text: "More").hover
        click_on "Writing & Publishing"

        within "[role=menubar]" do
          expect(page).to have_selector("[aria-current=true]", text: "More")
        end
      end

      it "resets filters when category is changed via nav" do
        visit "#{discover_host}/software-development?tags=othertag"

        within_section "On the market" do
          expect_product_cards_with_names("product 0")
        end

        within "[role=menubar]" do
          find("[role=menuitem]", text: "More").hover
          click_on "Software Development"
          click_on "All Software Development"
        end

        within_section "Featured products", section_element: :section do
          expect_product_cards_with_names("product 0", "product 3", "product 2", "product 1")
        end

        within_section "On the market" do
          expect(page).not_to have_product_card
        end
      end

      it "opens discover home when clicking the 'All' menubar item " do
        visit "#{discover_host}/business-and-money/entrepreneurship"

        click_on "All"

        within "[role=menubar]" do
          expect(page).to have_selector("[aria-current=true]", text: "All")
        end
      end

      it "changes category when clicking menubar item" do
        visit "#{discover_host}/software-development"

        within "[role=menubar]" do
          click_on "Business & Money"
        end

        expect(page).to have_selector("[aria-label='Breadcrumbs']", text: "Business & Money")
      end

      it "sorts categories based on sales recommendations, falling back to 30-day sales count" do
        seed_products
        UpdateTaxonomyStatsJob.new.perform

        visit discover_url(host: discover_host)
        expect(find("[role=menubar]")).to have_text("All 3D Software Development Audio Business & Money Comics & Graphic Novels Design Drawing & Painting Education Fiction Books More", normalize_ws: true)

        login_as @buyer
        visit discover_url(host: discover_host)
        # limit to 5 categories for logged in users
        expect(find("[role=menubar]")).to have_text("All 3D Software Development Audio Business & Money Comics & Graphic Novels More", normalize_ws: true)

        SalesRelatedProductsInfo.find_or_create_info(@product.id, create(:product, taxonomy: films_taxonomy).id).update!(sales_count: 20)
        rebuild_srpis_cache

        visit discover_url(host: discover_host)
        expect(find("[role=menubar]")).to have_text("All Films 3D Software Development Audio Business & Money More", normalize_ws: true)

        SalesRelatedProductsInfo.find_or_create_info(@product.id, create(:product, taxonomy: three_d_taxonomy).id).update!(sales_count: 21)
        rebuild_srpis_cache

        visit discover_url(host: discover_host)
        expect(find("[role=menubar]")).to have_text("All 3D Films Software Development Audio Business & Money More", normalize_ws: true)
      end
    end
  end

  it "shows the correct header CTAs when the user is logged out vs in" do
    visit discover_url(host: discover_host)
    header = first("header")
    expect(header).to_not have_link "Dashboard"
    expect(header).to have_link "Start selling", href: signup_url(host: UrlService.domain_with_protocol)
    expect(header).to have_link "Log in", href: login_url(host: UrlService.domain_with_protocol)
    expect(header).to_not have_link "Library"

    login_as create(:buyer_user)
    visit discover_url(host: discover_host)
    header = first("header")
    expect(header).to have_link "Dashboard", href: dashboard_url(host: UrlService.domain_with_protocol)
    expect(header).to_not have_link "Log in"
    expect(header).to have_link "Start selling", href: products_url(host: UrlService.domain_with_protocol)
    expect(header).to have_link "Library", href: library_url(host: UrlService.domain_with_protocol)

    login_as create(:compliant_user)
    visit discover_url(host: discover_host)
    header = first("header")
    expect(header).to_not have_link "Log in"
    expect(header).to have_link "Start selling", href: products_url(host: UrlService.domain_with_protocol)
    expect(header).to have_link "Library", href: library_url(host: UrlService.domain_with_protocol)
  end

  it "shows the footer" do
    visit "#{discover_host}/#{films_taxonomy.slug}"

    expect(page).to have_text("Subscribe to get tips and tactics to grow the way you want.")
  end
end
