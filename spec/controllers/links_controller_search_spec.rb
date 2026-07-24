# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

# Companion to the Minitest port of links_controller_spec (#5801).
#
# The `GET search` and the page-view "data recorded" examples index records into
# Elasticsearch and query them back, so they need a real ES cluster. The
# lightweight `test_minitest` CI job intentionally provides only
# mysql/redis/stripe_mock/mongo (no Elasticsearch) — the Minitest harness stubs
# ES process-wide — so these examples stay in RSpec, whose CI boots ES, rather
# than moving to test/controllers/links_controller_test.rb with the rest of the
# file. The nesting/description chain is preserved so any VCR/index conventions
# resolve exactly as before.
describe LinksController, :vcr, inertia: true do
  render_views

  context "within consumer area" do
    before do
      @user = create(:user)
    end
    let(:product) { create(:product, user: @user) }

    describe "POST increment_views" do
      before do
        @product = create(:product)
        @request.env["HTTP_USER_AGENT"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
        ElasticsearchIndexerWorker.jobs.clear
      end

      describe "data recorded", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        let(:last_page_view_data) do
          ProductPageView.search({ sort: { timestamp: :desc }, size: 1 }).first["_source"]
        end

        before do
          recreate_model_index(ProductPageView)
          travel_to Time.utc(2021, 1, 1)
          sign_in @user
        end

        it "sets basic data" do
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data).to equal_with_indifferent_access(
            product_id: @product.id,
            seller_id: @product.user_id,
            country: nil,
            state: nil,
            referrer_domain: "direct",
            timestamp: "2021-01-01T00:00:00Z",
            user_id: @user.id,
            ip_address: "0.0.0.0",
            url: "/links/#{@product.unique_permalink}/increment_views",
            browser_guid: cookies[:_gumroad_guid],
            browser_fingerprint: Digest::MD5.hexdigest(@request.env["HTTP_USER_AGENT"] + ","),
            referrer: nil,
          )
        end

        it "sets country and state from custom IP address" do
          @request.remote_ip = "54.234.242.13"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            country: "United States",
            state: "VA",
            ip_address: "54.234.242.13",
          )
        end

        it "sets referrer" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "youtube.com",
            referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          )
        end

        it "sets referrer via HTTP header" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "youtube.com",
            referrer: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          )
        end

        it "sets referrer via params" do
          post :increment_views, params: {
            id: @product.to_param,
            referrer: "https://gum.co/posts/news-新しい?#{"1" * 200}&extra",
          }
          expect(last_page_view_data.with_indifferent_access).to include(
            referrer_domain: "gum.co",
            referrer: "https://gum.co/posts/news-?#{"1" * 164}", # limited to first 190 chars
          )
        end

        it "sets custom browser_guid" do
          cookies[:_gumroad_guid] = "custom_guid"
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data[:browser_guid]).to eq("custom_guid")
        end

        it "sets user_id to nil when the user is signed out" do
          sign_out @user
          post :increment_views, params: { id: @product.to_param }
          expect(last_page_view_data[:user_id]).to eq(nil)
        end

        it "sets correct referrer_domain when product is not recommended" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: {
            id: @product.to_param,
            was_product_recommended: false
          }
          expect(last_page_view_data[:referrer_domain]).to eq("youtube.com")
        end

        it "sets correct referrer_domain when product is recommended" do
          @request.env["HTTP_REFERER"] = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          post :increment_views, params: {
            id: @product.to_param,
            was_product_recommended: true
          }
          expect(last_page_view_data[:referrer_domain]).to eq("recommended_by_gumroad")
        end
      end
    end

    describe "GET search" do
      before do
        @recommended_by = "search"
        @on_profile = false
      end

      def product_json(product, target, query = request.params["query"])
        ProductPresenter.card_for_web(product:, request: @request, recommended_by: @recommended_by, show_seller: !@on_profile, target:, query:).as_json
      end

      it "accepts a string ids param when searching by user" do
        Link.__elasticsearch__.create_index!(force: true)
        creator = create(:compliant_user, username: "creatordudey", name: "Creator Dudey")
        section = create(:seller_profile_products_section, seller: creator)
        product = create(:product, name: "Top quality weasel", user: creator)
        other_product = create(:product, name: "First product", user: creator)
        section.update!(shown_products: [other_product, product].map { _1.id })
        Link.import(force: true, refresh: true)

        @recommended_by = nil
        @on_profile = true

        get :search, params: {
          user_id: creator.external_id,
          section_id: section.external_id,
          ids: product.external_id
        }

        expect(response).to be_successful
        expect(response.parsed_body["products"]).to eq([product_json(product, "profile")])
      end

      it "searches by explicit ids when the section is not persisted yet" do
        Link.__elasticsearch__.create_index!(force: true)
        creator = create(:compliant_user, username: "creatordudey", name: "Creator Dudey")
        product = create(:product, name: "Top quality weasel", user: creator)
        other_product = create(:product, name: "First product", user: creator)
        Link.import(force: true, refresh: true)

        @recommended_by = nil
        @on_profile = true

        get :search, params: {
          user_id: creator.external_id,
          section_id: "0b8f3782-3a85-4f93-8e3c-2b1f5d3e8a90",
          ids: [other_product.external_id, product.external_id].join(","),
          sort: ProductSortKey::PAGE_LAYOUT,
        }

        expect(response).to be_successful
        expect(response.parsed_body["products"]).to eq([product_json(other_product, "profile"), product_json(product, "profile")])
      end

      describe "Setting and ordering" do
        before do
          Link.__elasticsearch__.create_index!(force: true)
          @creator = create(:compliant_user, username: "creatordudey", name: "Creator Dudey")
          @section = create(:seller_profile_products_section, seller: @creator)
          @product = create(:product, name: "Top quality weasel", user: @creator, taxonomy: Taxonomy.find_or_create_by(slug: "3d"))
          create(:purchase, :with_review, link: @product, created_at: 1.week.ago)
          create(:product_review, link: @product)
          Link.import(force: true, refresh: true)
        end

        it "returns the expected JSON response when no search parameters are specified" do
          res = {
            "total" => 1,
            "filetypes_data" => [],
            "tags_data" => [],
            "products" => [product_json(@product, "discover")]
          }
          get :search
          expect(response.parsed_body).to eq(res)

          get :search, params: { query: "" }
          expect(response.parsed_body).to eq(res)
        end

        it "returns the expected JSON response when searching by a user" do
          @product.tag!("mustelid")
          @on_profile = true
          @recommended_by = nil
          another_product = create(:product, name: "Another product", user: @creator)
          products = create_list(:product, 20, user: @creator)
          product3 = create(:product, user: @creator)
          create(:product_file, link: another_product)
          create(:product, name: "Bad product", user: @creator)
          shown_products = [@product, product3, another_product] + products
          @section.update!(shown_products: shown_products.map { _1.id })
          Link.import(force: true, refresh: true)

          get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }

          expect(response.parsed_body).to eq({
                                               "total" => 23,
                                               "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                                               "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                                               "products" => shown_products[0...9].map { product_json(_1, "profile") }
                                             })
        end


        it "returns products in page layout order when applicable if searching by user" do
          @recommended_by = nil
          @on_profile = true
          product_b = create(:product, name: "First product", user: @creator)
          product_c = create(:product, name: "Second product", user: @creator)
          create(:product, name: "Hide me", user: @creator)
          @section.update!(shown_products: [product_b, product_c, @product].map { _1.id })
          Link.import(force: true, refresh: true)

          get :search, params: { user_id: @creator.external_id, section_id: @section.external_id }
          expect(response.parsed_body["products"]).to eq([product_json(product_b, "profile"), product_json(product_c, "profile"), product_json(@product, "profile")])
        end

        it "returns an empty response when searching by non-existent user" do
          get :search, params: { user_id: 1640736000000, section_id: @section.id }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })
        end

        it "returns an empty response when searching by non-existent section" do
          get :search, params: { user_id: @creator.external_id, section_id: 1640736000000 }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })

          section = create(:seller_profile_posts_section, seller: @creator)
          get :search, params: { user_id: @creator.external_id, section_id: section.id }
          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })
        end

        it "returns all the creator's live profile products for the virtual default products section" do
          @recommended_by = nil
          @on_profile = true
          # The default products section only exists for creators with no saved sections, so
          # remove the one this describe block sets up.
          @section.destroy!
          another_product = create(:product, name: "Another product", user: @creator)
          Link.import(force: true, refresh: true)

          get :search, params: { user_id: @creator.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

          expect(response).to be_successful
          expect(response.parsed_body["total"]).to eq(2)
          expect(response.parsed_body["products"]).to match_array([product_json(@product, "profile"), product_json(another_product, "profile")])
        end

        it "returns an empty response for the default products section id when the creator has saved sections" do
          # A creator with real sections controls exactly which products show on their profile;
          # the virtual section id must not offer a way around that.
          get :search, params: { user_id: @creator.external_id, section_id: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID }

          expect(response.parsed_body).to eq({ "total" => 0, "tags_data" => [], "filetypes_data" => [], "products" => [] })
        end


        it "searches only for recommendable products" do
          bad_text = "Previously-owned weasel"
          bad = create(:product, name: bad_text)
          @product.tag!("mustelid")
          bad.tag!("irrelevant")
          create(:product_file, link: @product)
          create(:product_review, purchase: create(:purchase, link: @product, created_at: 1.month.ago))
          Link.import(force: true, refresh: true)

          get :search, params: { query: "weasel" }

          expect(response.parsed_body).to eq({
                                               "total" => 1,
                                               "filetypes_data" => [{ "doc_count" => 1, "key" => "pdf" }],
                                               "tags_data" => [{ "doc_count" => 1, "key" => "mustelid" }],
                                               "products" => [product_json(@product, "discover")]
                                             })
        end

        it "returns product in fee revenue order" do
          products = %i[meh unpopular popular old].each_with_object({}) do |name, h|
            h[name] = create(:product)
            h[name].tag!("ocelot")
            expect(h[name]).to receive(:recommendable?).at_least(:once).and_return(true)
          end
          travel_to(4.months.ago) { 4.times { create(:purchase, link: products[:old]) } }
          3.times { create(:purchase, link: products[:popular]) }
          2.times { create(:purchase, link: products[:meh]) }
          create(:purchase, link: products[:unpopular])
          index_model_records(Purchase)
          products.each do |_key, product|
            allow(product).to receive(:reviews_count).and_return(1)
            product.__elasticsearch__.index_document
            allow(product).to receive(:reviews_count).and_call_original
          end
          Link.__elasticsearch__.refresh_index!
          get :search, params: { query: "ocelot" }

          expect(response.parsed_body["products"]).to eq([
                                                           product_json(products[:popular], "discover"),
                                                           product_json(products[:meh], "discover"),
                                                           product_json(products[:unpopular], "discover"),
                                                           product_json(products[:old], "discover")
                                                         ])
        end

        it "searches successfully for a product with a regex character" do
          @product.update(name: "Top [quality weasel")
          Link.import(force: true, refresh: true)
          get :search, params: { query: "Top [quality" }
          expect(response.parsed_body["products"]).to eq([product_json(@product, "discover")])
        end
      end

      describe "Loose and exact matching" do
        before do
          Link.__elasticsearch__.create_index!(force: true)
          @products = {
            name: create(:product, name: "North American river otter"),
            desc: create(:product, description: "The North American river otter, also known as the northern river otter or the common otter, is a semiaquatic mammal."),
            creator: create(:product, user: create(:user, name: "Brig. Gen. W. North American River Otter III")),
            inexact: create(:product, description: "An American otter is found in the north river."),
            partial: create(:product, name: "Just an ordinary otter"),
            cross_field: create(:product, name: "River otter", description: "Animals of this description are common and live in the North and the South of the American and European continents."),
            tagged: create(:product, name: "River otter")
          }
          @products[:tagged].tag!("North American")
          @products[:tagged].tag!("common")
          @products.each do |_key, product|
            expect(product).to receive(:recommendable?).at_least(:once).and_return(true)
            allow(product).to receive(:reviews_count).and_return(1)
            product.__elasticsearch__.index_document
            allow(product).to receive(:reviews_count).and_call_original
          end
          Link.__elasticsearch__.refresh_index!
          sleep 0.5
        end

        it "finds all matches if exact match not specified" do
          get :search, params: { query: "north american river otter" }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator inexact cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "finds exact match if double-quotes used" do
          get :search, params: { query: '" north american river otter  "' }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator].map { |key| product_json(@products[key], "discover") })
        end

        it "finds compound match when double-quotes used in combination with another term" do
          get :search, params: { query: 'common "river otter"' }
          expect(response.parsed_body["products"]).to match_array(%i[desc cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "finds results for a complex match across different fields" do
          get :search, params: { query: 'north "river otter" american' }
          expect(response.parsed_body["products"]).to match_array(%i[name desc creator cross_field tagged].map { |key| product_json(@products[key], "discover") })
        end

        it "handles potentially malformed query" do
          get :search, params: { query: "\\" }
          expect(response.parsed_body["products"]).to eq([])
        end
      end

      describe "Filtering" do
        describe "for products with no reviews" do
          before do
            @user = create(:recommendable_user)
            @section = create(:seller_profile_products_section, seller: @user)
            @product_without_review = create(:product, name: "sample 2", user: @user)
            @product_with_review = create(:product, :recommendable, name: "sample 1", user: @user)
            create(:product_review, purchase: create(:purchase, link: @product_with_review))

            Link.__elasticsearch__.refresh_index!
          end

          it "filters on discover" do
            get :search, params: { query: "sample" }
            expect(response.parsed_body["products"]).to eq([product_json(@product_with_review, "discover")])
          end

          it "does not filter on profile" do
            @recommended_by = nil
            @on_profile = true
            get :search, params: { user_id: @user.external_id, section_id: @section.external_id }
            expect(response.parsed_body["products"]).to eq([product_json(@product_without_review, "profile"), product_json(@product_with_review, "profile")])
          end
        end
      end

      describe "Discover tracking" do
        it "stores the search query along with useful metadata" do
          cookies[:_gumroad_guid] = "custom_guid"
          sign_in @user

          expect do
            get :search, params: { query: "something", taxonomy: "3d" }
          end.to change(DiscoverSearch, :count).by(1)

          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "user_id" => @user.id,
            "taxonomy_id" => Taxonomy.find_by_path(["3d"]).id,
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => false
          )
        end

        it "does not store search when querying user products" do
          expect do
            get :search, params: { query: "something", user_id: @user.id }
          end.not_to change(DiscoverSearch, :count)
        end
      end
    end
  end
end
