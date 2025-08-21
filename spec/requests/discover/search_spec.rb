# frozen_string_literal: true

require "spec_helper"

describe("Discover - Search scenarios", js: true, type: :system) do
  let(:discover_host) { UrlService.discover_domain_with_protocol }

  before do
    allow_any_instance_of(Link).to receive(:update_asset_preview)
    @buyer = create(:user)
    @png = Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "kFDzu.png"), "image/png")
  end

  def seed_products
    travel_to(5.seconds.ago) do
      @product = create(:product, :recommendable, :with_design_taxonomy, user: create(:compliant_user, name: "Gumstein"), name: "product 0")
    end
    travel_to(4.seconds.ago) do
      @similar_product_1 = create(:product, :recommendable, :with_design_taxonomy, user: create(:compliant_user, name: "Gumstein II"), name: "product 1", preview: @png, price_cents: 200)
    end
    travel_to(3.seconds.ago) do
      @similar_product_2 = create(:product, :recommendable, :with_design_taxonomy, user: create(:compliant_user, name: "Gumstein III"), name: "product 2", preview: @png, price_cents: 300)
    end
    travel_to(2.seconds.ago) do
      @similar_product_3 = create(:product, :recommendable, :with_design_taxonomy, user: create(:compliant_user, name: "Gumstein IV"), name: "product 3", preview: @png, price_cents: 400)
    end
    travel_to(1.second.ago) do
      @similar_product_4 = create(:product, :recommendable, :with_design_taxonomy, user: create(:compliant_user, name: "Gumstein V"), name: "product 4", preview: @png, price_cents: 500)
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
    @films = Taxonomy.find_or_create_by(slug: "films")
  end

  def within_search_autocomplete(&block)
    within find(:combo_box_list_box, find(:combo_box, "Search products")), &block
  end

  describe "search" do
    it "shows search results for recommendable products" do
      recommendable_product_title = "Nothing but pine martens"
      recommendable_product = create(:product, :recommendable, name: recommendable_product_title, price_cents: 3378)
      create(:product, name: "These pine martens we don't like so much")

      index_model_records(Link)

      visit discover_url(host: discover_host)

      fill_in "Search products", with: "pine martens\n"
      expect_product_cards_in_order([recommendable_product])
      click_on recommendable_product_title
      wait_for_ajax

      expect do
        add_to_cart(recommendable_product, cart: true)
        check_out(recommendable_product)
      end.to change { recommendable_product.sales.successful.select(&:was_discover_fee_charged?).count }.by(1)
         .and change { RecommendedPurchaseInfo.where(recommendation_type: "search").count }.by(1)
    end

    it "does not show product in search results if seller is not compliant" do
      recommendable_product_title = "Nothing but pine martens"
      recommendable_product = create(:product, :recommendable, name: recommendable_product_title, price_cents: 3378)
      index_model_records(Link)
      expect(recommendable_product.recommendable?).to be(true)

      visit discover_url(host: discover_host)
      fill_in "Search products", with: "pine martens\n"
      expect_product_cards_in_order([recommendable_product])

      recommendable_product.user.update!(user_risk_state: "not_reviewed")
      recommendable_product.enqueue_index_update_for(%w[is_recommendable])
      expect(recommendable_product.recommendable?).to be(false)

      visit discover_url(host: discover_host)
      fill_in "Search products", with: "pine martens\n"
      expect(page).not_to have_selector(".product-card")
    end

    it "shows autocomplete results for products" do
      create(:product, :recommendable, name: "Rust: The best parts")
      create(:product, :recommendable, name: "Why Rust is better than C++", price_cents: 3378)
      create(:product, name: "We don't recommend C++")

      index_model_records(Link)

      visit discover_url(host: discover_host)

      find_field("Search products").click
      within_search_autocomplete do
        expect(page).to have_text("Trending")
        expect(page).to have_selector("[role=option]", text: "Why Rust is better than C++")
        expect(page).to have_selector("[role=option]", text: "Rust: The best parts")
      end

      # ensure autocomplete requests don't show up if we do a full search
      fill_in "Search products", with: "c++\n"
      sleep 1
      wait_for_ajax
      expect(page).to_not have_selector("[role=option]", text: "Why Rust is better than C++")

      fill_in "Search products", with: "c++"
      within_search_autocomplete do
        expect(page).to have_text("Products")
        expect(page).to have_selector("[role=option]", text: "Why Rust is better than C++")
        expect(page).to_not have_selector("[role=option]", text: "We don't recommend C++")
      end
    end

    it "shows autocomplete results for recently viewed products" do
      login_as @buyer

      create(:product, :recommendable, name: "Rust: The best parts")
      visited1 = create(:product, :recommendable, name: "Why Rust is better than C++")
      visited2 = create(:product, :recommendable, name: "The ideal systems programming language")
      non_recommendable = create(:product, name: "We don't recommend C++")
      index_model_records(Link)

      add_page_view(visited1, Time.current, user_id: @buyer.id)
      add_page_view(visited2, Time.current, user_id: @buyer.id)
      add_page_view(non_recommendable, Time.current, user_id: @buyer.id)
      ProductPageView.__elasticsearch__.refresh_index!

      visit discover_url(host: discover_host)

      find_field("Search products").click
      within_search_autocomplete do
        expect(page).to have_text("Keep shopping for")
        expect(page).to have_selector("[role=option]", text: "The ideal systems programming language")
        expect(page).to have_selector("[role=option]", text: "Why Rust is better than C++")
        expect(page).to_not have_selector("[role=option]", text: "Rust: The best parts")
        expect(page).to_not have_selector("[role=option]", text: "We don't recommend C++")
      end
    end

    it "shows autocomplete results for recent searches" do
      login_as @buyer
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: @buyer, query: "c++"))
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: @buyer, query: "rust"))

      visit discover_url(host: discover_host)

      find_field("Search products").click
      expect(page).to have_selector("[role=option]", text: "rust")
      expect(page).to have_selector("[role=option]", text: "c++")

      fill_in "Search products", with: "c++"
      expect(page).not_to have_selector("[role=option]", text: "rust")
      expect(page).to have_selector("[role=option]", text: "c++")
    end

    it "supports deleting recent searches" do
      login_as @buyer
      create(:discover_search_suggestion, discover_search: create(:discover_search, user: @buyer, query: "c++"))
      rust_search = create(:discover_search_suggestion, discover_search: create(:discover_search, user: @buyer, query: "rust"))

      visit discover_url(host: discover_host)

      find_field("Search products").click
      within("[role=option]", text: "rust") do
        click_on "Remove"
      end
      expect(page).not_to have_selector("[role=option]", text: "rust")
      wait_for_ajax
      expect(rust_search.reload).to be_deleted
    end

    context "when searching with an empty query", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      before do
        seed_products
        @similar_product_1.update(taxonomy: @films)
        @similar_product_3.update(taxonomy: @films)
        Link.import(refresh: true, force: true)
      end

      it "shows relevant products when no category is selected" do
        visit discover_url(host: discover_host)
        wait_for_ajax

        fill_in "Search products", with: "product"
        find_field("Search products").native.send_keys(:return)

        expect(page).to have_current_path("/discover?query=product")
        expect(page).to have_product_card(count: 5)
      end

      it "loads category page when category card is clicked" do
        visit discover_url(host: discover_host)
        wait_for_ajax

        within "[role=menubar]" do
          click_on "Design"
        end

        within("header [role=navigation]") do
          expect(page).to have_text("Design")
        end
        within_section("Featured products", section_element: :section) do
          expect(page).to have_product_card(count: 3)
        end
      end

      it "shows the top products for a non-empty category" do
        visit discover_url(host: discover_host)
        wait_for_ajax

        within "[role=menubar]" do
          click_on "Design"
        end
        wait_for_ajax

        fill_in "Search products", with: "product"
        find_field("Search products").native.send_keys(:return)

        expect(page).to have_current_path("/design?query=product")

        within("[role=navigation][aria-label='Breadcrumbs']") do
          expect(page).to have_text("Design")
        end
        expect(page).to have_product_card(count: 3)
      end

      context "when searching with tags param", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        before do
          @similar_product_1.tag!("test")
        end

        it "shows top products for selected tag" do
          visit discover_url(host: discover_host, tags: "test")
          wait_for_ajax

          within_section("On the market", section_element: :section) do
            expect(page).to have_product_card(count: 1)
            within(find_product_card(@similar_product_1)) do
              expect(page).to have_content(@similar_product_1.name)
              expect(page).to have_link(@similar_product_1.user.name)
            end
          end
        end

        it "allows search results filtering" do
          @similar_product_2.tag!("test")
          @similar_product_3.tag!("test")

          visit discover_url(host: discover_host, tags: "test")
          wait_for_ajax

          within_section("On the market", section_element: :section) do
            expect(page).to have_product_card(count: 3)
            select_disclosure "Price" do
              fill_in("Maximum price", with: 2)
            end
            wait_for_ajax
            expect(page).to have_product_card(count: 1)
          end
        end
      end
    end
  end
end
