# frozen_string_literal: true

require "spec_helper"
require "shared_examples/affiliate_cookie_concern"
require "shared_examples/authorize_called"
require "shared_examples/collaborator_access"
require "shared_examples/with_sorting_and_pagination"
require "inertia_rails/rspec"

def e404_test(action)
  it "404s when link isn't found" do
    expect { get action, params: { id: "NOT real" } }.to raise_error(ActionController::RoutingError)
  end
end

describe LinksController, :vcr, inertia: true do
  render_views

  context "within seller area" do
    let(:seller) { create(:named_seller) }

    include_context "with user signed in as admin for seller"

    describe "GET index" do
      it_behaves_like "authorize called for action", :get, :index do
        let(:record) { Link }
      end

      it "renders the Products/Index component with correct props" do
        get :index

        expect(response).to be_successful
        expect(inertia).to render_component("Products/Index")
        expect(inertia.props).to include(
          :archived_products_count,
          :can_create_product,
          :products_data,
          :memberships_data
        )
        expect(inertia.props[:products_data]).to include(:products, :pagination, :sort)
        expect(inertia.props[:memberships_data]).to include(:memberships, :pagination, :sort)
      end
    end

    %w[unpublish publish destroy].each do |action|
      describe "##{action}" do
        e404_test(action.to_sym)
      end
    end

    describe "POST publish" do
      before do
        @disabled_link = create(:physical_product, purchase_disabled_at: Time.current, user: seller)
      end

      it_behaves_like "authorize called for action", :post, :publish do
        let(:record) { @disabled_link }
        let(:request_params) { { id: @disabled_link.unique_permalink } }
      end

      it_behaves_like "collaborator can access", :post, :publish do
        let(:product) { @disabled_link }
        let(:request_params) { { id: @disabled_link.unique_permalink } }
        let(:response_attributes) { { "success" => true } }
      end

      it "enables a disabled link" do
        post :publish, params: { id: @disabled_link.unique_permalink }

        expect(response.parsed_body["success"]).to eq(true)
        expect(@disabled_link.reload.purchase_disabled_at).to be_nil
      end

      context "when link is not publishable" do
        before do
          allow_any_instance_of(Link).to receive(:publishable?) { false }
        end

        it "returns an error message" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["error_message"]).to eq("You must connect at least one payment method before you can publish this product for sale.")
        end

        it "does not publish the link" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@disabled_link.reload.purchase_disabled_at).to be_present
        end
      end

      context "when user email is not confirmed" do
        before do
          seller.update!(confirmed_at: nil)
          @unpublished_product = create(:physical_product, purchase_disabled_at: Time.current, user: seller)
        end

        it "returns an error message" do
          post :publish, params: { id: @unpublished_product.unique_permalink }
          expect(response.parsed_body["error_message"]).to eq("You have to confirm your email address before you can do that.")
        end

        it "does not publish the link" do
          post :publish, params: { id: @unpublished_product.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@unpublished_product.reload.purchase_disabled_at).to be_present
        end
      end

      context "when an unknown exception is raised" do
        before do
          allow_any_instance_of(Link).to receive(:publish!).and_raise("error")
        end

        it "sends a Bugsnag notification" do
          expect(Bugsnag).to receive(:notify).once

          post :publish, params: { id: @disabled_link.unique_permalink }
        end

        it "returns an error message" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["error_message"]).to eq("Something broke. We're looking into what happened. Sorry about this!")
        end

        it "does not publish the link" do
          post :publish, params: { id: @disabled_link.unique_permalink }

          expect(response.parsed_body["success"]).to eq(false)
          expect(@disabled_link.reload.purchase_disabled_at).to be_present
        end
      end
    end

    describe "POST unpublish" do
      it_behaves_like "collaborator can access", :post, :unpublish do
        let(:product) { create(:product, user: seller) }
        let(:request_params) { { id: product.unique_permalink } }
        let(:response_attributes) { { "success" => true } }
      end
    end

    describe "PUT sections" do
      let(:product) { create(:product, user: seller) }
      it_behaves_like "authorize called for action", :put, :update_sections do
        let(:record) { product }
        let(:request_params) { { id: product.unique_permalink } }
      end

      it_behaves_like "collaborator can access", :put, :update_sections do
        let(:response_status) { 204 }
        let(:request_params) { { id: product.unique_permalink } }
      end

      it "updates the SellerProfileSections attached to the product and cleans up orphaned sections" do
        sections = create_list(:seller_profile_products_section, 2, seller:, product:)
        create(:seller_profile_posts_section, seller:, product:)
        create(:seller_profile_posts_section, seller:)

        put :update_sections, params: { id: product.unique_permalink, sections: sections.map(&:external_id), main_section_index: 1 }

        expect(product.reload).to have_attributes(sections: sections.map(&:id), main_section_index: 1)
        expect(seller.seller_profile_sections.count).to eq 3
        expect(seller.seller_profile_sections.on_profile.count).to eq 1
      end
    end

    describe "DELETE destroy" do
      describe "suspended tos violation user" do
        before do
          @admin_user = create(:user)
          @product = create(:product, user: seller)

          seller.flag_for_tos_violation(author_id: @admin_user.id, product_id: @product.id)
          seller.suspend_for_tos_violation(author_id: @admin_user.id)

          # NOTE: The invalidate_active_sessions! callback from suspending the user, interferes
          # with the login mechanism, this is a hack get the `sign_in user` method work correctly
          request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
        end

        it_behaves_like "authorize called for action", :delete, :destroy do
          let(:record) { @product }
          let(:request_params) { { id: @product.unique_permalink } }
        end

        it "allows deletion if user suspended (tos)" do
          delete :destroy, params: { id: @product.unique_permalink }
          expect(@product.reload.deleted_at.present?).to be(true)
        end
      end
    end


    describe "GET show" do
      e404_test(:show)

      before do
        @user = create(:user, :eligible_for_service_products)
        @request.host = URI.parse(@user.subdomain_with_protocol).host
      end

      %w[preview_url description].each do |w|
        it "renders when no #{w}" do
          Rails.cache.clear
          link = create(:product, user: @user, w => nil)
          get :show, params: { id: link.to_param }
          expect(response).to be_successful
        end
      end

      describe "wanted=true parameter" do
        it "passes pay_in_installments parameter to checkout when wanted=true" do
          get :show, params: { id: product.to_param, wanted: "true", pay_in_installments: "true" }

          expect(response).to be_redirect

          redirect_url = URI.parse(response.location)
          expect(redirect_url.path).to eq("/checkout")

          query_params = Rack::Utils.parse_query(redirect_url.query)
          expect(query_params).to include(
            "product" => product.unique_permalink,
            "price" => product.price_cents.to_s,
            "pay_in_installments" => "true",
          )
        end

        it "doesn't redirect to checkout for PWYW products without price" do
          product = create(:product, user: @user, customizable_price: true, price_cents: 1000)

          get :show, params: { id: product.to_param, wanted: "true" }

          expect(response).to be_successful
          expect(response).not_to be_redirect
        end
      end

      context "with user signed in" do
        let(:visitor) { create(:user) }
        let!(:purchase) { create(:purchase, purchaser: visitor, link: product) }

        before do
          sign_in(visitor)
        end

        it "assigns the correct props" do
          get :show, params: { id: product.to_param }

          expect(response).to be_successful
          product_props = assigns(:product_props)
          expect(product_props[:product][:id]).to eq(product.external_id)
          expect(product_props[:purchase][:id]).to eq(purchase.external_id)
        end
      end

      describe "meta tags sanitization" do
        it "properly escapes double quote in content" do
          link = create(:product, user: @user, description: 'I like pie."')
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)

          # nokogiri decodes html entities in tag attributes,
          # so checking for `I like pie."` means you're actually checking for `I like pie.&quot;`
          expect(html_doc.css("meta[name='description'][content='I like pie.\"']")).to_not be_empty
        end

        it "scrubs tags in content" do
          link = create(:product, user: @user, description: "I like pie.&nbsp; <br/>")
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)

          expect(html_doc.css("meta[name='description'][content='I like pie.']")).to_not be_empty
        end

        it "escapes new lines and html tags" do
          link = create(:product, user: @user, description: "I like pie.\n\r This is not <br/> what we had estimated! ~")
          get :show, params: { id: link.to_param }
          expect(response).to be_successful

          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[name='description'][content='I like pie. This is not what we had estimated! ~']")).to_not be_empty
        end
      end

      describe "asset previews" do
        before do
          @product = create(:product_with_file_and_preview, user: @user)
        end

        it "renders the preview container" do
          get(:show, params: { id: @product.to_param })

          expect(response).to be_successful
          expect(response.body).to have_selector("[role=tabpanel][id='#{@product.asset_previews.first.guid}']")
        end

        it "shows preview navigation controls when there is more than one preview" do
          get(:show, params: { id: @product.to_param })
          expect(response.body).to_not have_button("Show next cover")
          expect(response.body).to_not have_tablist("Select a cover")
          create(:asset_preview, link: @product)
          get(:show, params: { id: @product.to_param })
          expect(response.body).to have_tablist("Select a cover")
          expect(response.body).to have_button("Show next cover")
        end
      end

      context "when custom_permalink exists" do
        let(:product) { create(:product, user: @user, custom_permalink: "custom") }

        it "redirects from unique_permalink to custom_permalink URL preserving the original query parameter string" do
          get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

          expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
        end
      end

      describe "redirection to creator's subdomain" do
        before do
          @request.host = DOMAIN
        end

        context "when requested with unique permalink" do
          context "when custom permalink is not present" do
            it "redirects to the subdomain product URL with original query params" do
              product = create(:product)
              get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_url(product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end

          context "when custom permalink is present" do
            it "redirects to the subdomain product URL using custom permalink with original query params" do
              product = create(:product, custom_permalink: "abcd")
              get :show, params: { id: product.unique_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end

          context "when offer code is present" do
            it "redirects to subdomain product URL with offer code and original query params" do
              product = create(:product)
              get :show, params: { id: product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_offer_code_url(product.unique_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end
        end

        context "when requested with custom permalink" do
          it "redirects to the subdomain product URL using custom permalink with original query params" do
            product = create(:product, custom_permalink: "abcd")
            get :show, params: { id: product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

            expect(response).to redirect_to(short_link_url(product.custom_permalink, as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
            expect(response).to have_http_status(:moved_permanently)
          end

          context "when offer code is present" do
            it "redirects to subdomain product URL with offer code and original query params" do
              product = create(:product, custom_permalink: "abcd")
              get :show, params: { id: product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com" }

              expect(response).to redirect_to(short_link_offer_code_url(product.custom_permalink, code: "123", as_embed: true, affiliate_id: 12345, origin: "https://example.com", host: product.user.subdomain_with_protocol))
              expect(response).to have_http_status(:moved_permanently)
            end
          end
        end
      end

      context "when the product is deleted" do
        let(:product) { create(:product, user: @user, deleted_at: 2.days.ago) }

        it "returns 404" do
          expect do
            get :show, params: { id: product.to_param }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      context "when the product is a coffee product" do
        let!(:product) { create(:product, user: @user, native_type: Link::NATIVE_TYPE_COFFEE) }

        it "redirects to the coffee page" do
          expect(get :show, params: { id: product.to_param }).to redirect_to(custom_domain_coffee_url)
        end
      end

      context "when the user is deleted" do
        let(:user) { create(:user, deleted_at: 2.days.ago) }
        let(:product) { create(:product, custom_permalink: "moohat", user:) }

        it "responds with 404" do
          expect do
            get :show, params: { id: product.to_param }
          end.to raise_error(ActionController::RoutingError)
        end
      end

      it "does not 404 if user is not suspended" do
        link = create(:product, user: @user)
        expect { get :show, params: { id: link.to_param } }.to_not raise_error
      end

      it "404s on an unsupported format" do
        link = create(:product, user: @user)
        expect do
          get(:show, params: { id: link.to_param, format: :php })
        end.to raise_error(ActionController::RoutingError)
      end

      describe "canonical urls" do
        it "renders the canonical meta tag" do
          product = create(:product, user: @user)

          get :show, params: { id: product.unique_permalink }
          expect(response.body).to have_selector("link[rel='canonical'][href='#{product.long_url}']", visible: false)
        end
      end

      describe "product information markup" do
        it "renders schema.org item props for classic product" do
          product = create(:product, user: @user, price_currency_type: "usd", price_cents: 525)
          purchase = create(:purchase, link: product)
          create(:product_review, purchase:)
          create(:asset_preview, link: product, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false)

          get :show, params: { id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.body).to have_selector("[itemprop='offers'][itemtype='https://schema.org/Offer']")
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to have_selector("[itemprop='availability']", text: "https://schema.org/InStock", visible: false)
          expect(response.body).to have_selector("[itemprop='reviewCount']", text: product.reviews_count, visible: false)
          expect(response.body).to have_selector("[itemprop='ratingValue']", text: "1", visible: false)
          expect(response.body).to have_selector("[itemprop='price']", text: product.price_formatted_without_dollar_sign, visible: false)
          expect(response.body).to have_selector("[itemprop='seller'][itemtype='https://schema.org/Person']", visible: false)
          expect(response.body).to have_selector("[itemprop='name']", text: @user.name, visible: false)
          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to be_present
          expect(html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']")).to be_present
          expect(html_doc.css("meta[property='product:price:amount'][content='5.25']")).to be_present
          expect(html_doc.css("meta[property='product:price:currency'][content='USD']")).to be_present
          expect(html_doc.css("meta[content='#{product.preview_url}'][property='og:image']")).to be_present
        end

        it "renders schema.org item props for product over $1000" do
          product = create(:product, user: @user, price_cents: 1_000_00)
          purchase = create(:purchase, link: product)
          create(:product_review, purchase:)

          get :show, params: { id: product.unique_permalink }

          expect(response).to be_successful
          expect(response.body).to have_selector("[itemprop='offers'][itemtype='https://schema.org/Offer']")
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to have_selector("[itemprop='availability']", text: "https://schema.org/InStock", visible: false)
          expect(response.body).to have_selector("[itemprop='reviewCount']", text: product.reviews_count, visible: false)
          expect(response.body).to have_selector("[itemprop='ratingValue']", text: "1", visible: false)
          expect(response.body).to have_selector("[itemprop='price'][content='1000']")
          expect(response.body).to have_selector("[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          # Can't use assert_selector, it doesn't work for tags in head
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[property='product:retailer_item_id'][content='#{product.unique_permalink}']")).to_not be_empty
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to_not be_empty
        end

        it "does not render product review count and rating markup if product has no review" do
          product = create(:product, user: @user)
          get :show, params: { id: product.unique_permalink }
          expect(response.body).to have_selector("link[itemprop='url'][href='#{product.long_url}']")
          expect(response.body).to_not have_selector("div[itemprop='reviewCount']")
          expect(response.body).to_not have_selector("div[itemprop='ratingValue']")
          expect(response.body).to_not have_selector("div[itemprop='aggregateRating']")
          html_doc = Nokogiri::HTML(response.body)
          expect(html_doc.css("meta[content='#{product.long_url}'][property='og:url']")).to_not be_empty
        end

        it "renders schema.org item props for single-tier membership product" do
          recurrence_price_values = {
            BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.5 },
            BasePrice::Recurrence::BIANNUALLY => { enabled: true, price: 15 },
            BasePrice::Recurrence::YEARLY => { enabled: true, price: 30 },
          }
          product = create(:membership_product, user: @user)
          product.default_tier.save_recurring_prices!(recurrence_price_values)
          get :show, params: { id: product.unique_permalink }
          expect(response).to be_successful
          expect(response.body).to have_selector("div[itemprop='offers'][itemtype='https://schema.org/AggregateOffer']")
          expect(response.body).to have_selector("div[itemprop='offerCount']", text: "1", visible: false)
          expect(response.body).to have_selector("div[itemprop='lowPrice']", text: "2.50", visible: false)
          expect(response.body).to have_selector("div[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          expect(response.body).to have_selector("[itemprop='offer'][itemtype='https://schema.org/Offer']", count: 1)
          expect(response.body).to have_selector("div[itemprop='price']", text: "2.50", count: 2, visible: false)
        end

        it "renders schema.org item props for multi-tier membership product" do
          recurrence_price_values = [
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.5 } },
            { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 } }
          ]
          product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values:, user: @user)
          get :show, params: { id: product.unique_permalink }
          expect(response).to be_successful
          expect(response.body).to have_selector("div[itemprop='offers'][itemtype='https://schema.org/AggregateOffer']")
          expect(response.body).to have_selector("div[itemprop='offerCount']", text: "2", visible: false)
          expect(response.body).to have_selector("div[itemprop='lowPrice']", text: "2.50", visible: false)
          expect(response.body).to have_selector("div[itemprop='priceCurrency']", text: product.price_currency_type, visible: false)
          expect(response.body).to have_selector("[itemprop='offer'][itemtype='https://schema.org/Offer']", count: 2)
          expect(response.body).to have_selector("div[itemprop='price']", exact_text: "2.50", count: 1, visible: false)
          expect(response.body).to have_selector("div[itemprop='price']", exact_text: "5", count: 1, visible: false)
        end
      end

      it "does not set no index header by default" do
        product = create(:product, user: @user)
        get :show, params: { id: product.unique_permalink }
        expect(response.headers["X-Robots-Tag"]).to be_nil
      end

      context "adult products" do
        it "does not set the noindex header" do
          product = create(:product, user: @user, is_adult: true)

          get :show, params: { id: product.unique_permalink }

          expect(response.headers.keys).not_to include("X-Robots-Tag")
        end
      end

      context "non-alive products" do
        it "sets the noindex header" do
          product = create(:product, user: @user)
          expect_any_instance_of(Link).to receive(:alive?).at_least(:once).and_return(false)

          get :show, params: { id: product.unique_permalink }

          expect(response.headers["X-Robots-Tag"]).to eq("noindex")
        end
      end

      it "sets paypal_merchant_currency as merchant account's currency if native paypal payments are enabled else as usd" do
        product = create(:product, user: @user)

        get :show, params: { id: product.unique_permalink }
        expect(assigns[:paypal_merchant_currency]).to eq "USD"

        create(:merchant_account_paypal, user: product.user, currency: "GBP")
        get :show, params: { id: product.unique_permalink }
        expect(assigns[:paypal_merchant_currency]).to eq "GBP"
      end

      context "when requests come from custom domains" do
        let(:product) { create(:product) }
        let!(:custom_domain) { create(:custom_domain, domain: "www.example1.com", user: nil, product:) }

        before do
          @request.host = "www.example1.com"
        end

        context "when the custom domain matches a product's custom domain" do
          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end

        context "when the custom domain matches a deleted product" do
          before do
            product.mark_deleted!
          end

          it "raises ActionController::RoutingError" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end

        context "when the same domain name is used for a user's deleted custom domain and a product's active custom domain" do
          before do
            custom_domain.update!(product: nil, user: create(:user), deleted_at: DateTime.parse("2020-01-01"))
            create(:custom_domain, domain: "www.example1.com", user: nil, product:)
          end

          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end

        context "when a product's custom domain is deleted" do
          before do
            custom_domain.mark_deleted!
          end

          it "raises ActionController::RoutingError" do
            expect { get :show }.to raise_error(ActionController::RoutingError)
          end
        end

        context "when a product's saved custom domain does not use the www prefix" do
          before do
            custom_domain.update!(domain: "example1.com")
          end

          it "assigns the product and renders the show template" do
            get :show
            expect(response).to be_successful
            expect(assigns[:product]).to eq(product)
            expect(response).to render_template(:show)
          end
        end
      end

      context "when requests come from subdomains" do
        before do
          @user = create(:user, username: "testuser")
          @request.host = "#{@user.username}.test.gumroad.com"
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
        end

        context "when the subdomain and unique permalink are valid and present" do
          before do
            @product = create(:product, user: @user)
          end

          it "assigns the product and renders the show template" do
            get :show, params: { id: @product.unique_permalink }
            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
            expect(response).to render_template(:show)
          end
        end

        context "when the product has custom permalink but accessed through unique permalink" do
          before do
            @product = create(:product, user: @user, custom_permalink: "onetwothree")
          end

          it "redirects unique permalink to custom permalink" do
            get :show, params: { id: @product.unique_permalink }
            expect(response).to redirect_to(@product.long_url)
          end
        end

        context "when the subdomain and custom permalink are valid and present" do
          before do
            @product = create(:product, user: @user, custom_permalink: "test-link")
          end

          it "assigns the product and renders the show template" do
            get :show, params: { id: @product.custom_permalink }
            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
            expect(response).to render_template(:show)
          end
        end

        context "when the seller from subdomain is different from product's seller" do
          before do
            @product = create(:product, user: create(:user, username: "anotheruser"))
          end

          it "raises ActionController::RoutingError" do
            expect { get :show, params: { id: @product.unique_permalink } }.to raise_error(ActionController::RoutingError)
          end
        end
      end

      context "when request comes from a legacy product URL" do
        before do
          @product_1 = create(:product, unique_permalink: "abc", custom_permalink: "custom")
          @product_2 = create(:product, unique_permalink: "xyz", custom_permalink: "custom")
          @request.host = DOMAIN
        end

        context "when looked up by unique permalink" do
          it "redirects to a product URL with subdomain and custom permalink" do
            get :show, params: { id: "abc" }

            expect(response).to redirect_to(@product_1.long_url)
          end
        end

        context "when looked up by custom permalink" do
          it "redirects to a full product URL of the oldest product matched by custom permalink" do
            get :show, params: { id: "custom" }

            expect(response).to redirect_to(@product_1.long_url)
          end
        end
      end

      describe "legacy products lookup" do
        before do
          @user = create(:user)

          # product by another user, created earlier in time
          @other_product = create(:product, user: create(:user), custom_permalink: "custom")

          # product by another user with legacy permalink mapping
          @product_with_legacy_mapping = create(:product, user: create(:user), custom_permalink: "custom")
          create(:legacy_permalink, permalink: "custom", product: @product_with_legacy_mapping)

          # the user's product, created later in time
          @product = create(:product, user: @user, custom_permalink: "custom")
        end

        context "when request comes from a legacy URL" do
          before do
            @request.host = DOMAIN
          end

          it "redirects to a product defined by legacy permalink" do
            get :show, params: { id: "custom" }

            expect(response).to redirect_to(@product_with_legacy_mapping.long_url)
          end

          context "when legacy permalink points to a deleted product" do
            before do
              @product_with_legacy_mapping.mark_deleted!
            end

            it "redirects to an earlier product matched by permalink" do
              get :show, params: { id: "custom" }

              expect(response).to redirect_to(@other_product.long_url)
            end
          end
        end

        context "when request comes from a custom domain" do
          before do
            @domain = CustomDomain.create(domain: "www.example1.com", user: @user)
            @request.host = "www.example1.com"
          end

          it "renders the user's product" do
            get :show, params: { id: "custom" }

            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
          end
        end

        context "when request comes from a subdomain URL" do
          before do
            @request.host = "#{@user.username}.test.gumroad.com"
            stub_const("ROOT_DOMAIN", "test.gumroad.com")
          end

          it "renders the user's product" do
            get :show, params: { id: "custom" }

            expect(response).to be_successful
            expect(assigns[:product]).to eq(@product)
          end
        end
      end

      describe "setting affiliate cookie" do
        let(:product) { create(:product) }
        let(:direct_affiliate) { create(:direct_affiliate, seller: product.user, products: [product]) }
        let(:host) { URI.parse(product.user.subdomain_with_protocol).host }

        Affiliate::QUERY_PARAMS.each do |query_param|
          context "with `#{query_param}` query param" do
            it_behaves_like "AffiliateCookie concern" do
              subject(:make_request) do
                @request.host = host
                get :show, params: { id: product.unique_permalink, query_param => direct_affiliate.external_id_numeric }
              end
            end
          end
        end
      end

      it "adds X-Robots-Tag response header to avoid page indexing only if the url contains an offer code" do
        product = create(:product, unique_permalink: "abc", user: @user)

        get :show, params: { id: product.unique_permalink, code: "10off" }
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")

        get :show, params: { id: product.unique_permalink }
        expect(response.headers.keys).not_to include("X-Robots-Tag")

        get :show, params: { id: product.unique_permalink, code: "20off" }
        expect(response.headers["X-Robots-Tag"]).to eq("noindex")
      end

      describe "Discover tracking" do
        it "stores click when coming from discover" do
          cookies[:_gumroad_guid] = "custom_guid"

          expect do
            get :show, params: { id: product.to_param, recommended_by: "search", query: "something", autocomplete: "true" }
          end.to change(DiscoverSearch, :count).by(1)

          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => true,
            "clicked_resource_type" => product.class.name,
            "clicked_resource_id" => product.id,
          )

          expect do
            get :show, params: { id: product.to_param, recommended_by: "discover", query: "something" }
          end.to change(DiscoverSearch, :count).by(1)


          expect(DiscoverSearch.last!.attributes).to include(
            "query" => "something",
            "ip_address" => "0.0.0.0",
            "browser_guid" => "custom_guid",
            "autocomplete" => false,
            "clicked_resource_type" => product.class.name,
            "clicked_resource_id" => product.id,
          )
        end

        it "does not store click when not coming from discover" do
          expect do
            get :show, params: { id: product.to_param }
          end.not_to change(DiscoverSearch, :count)
        end
      end
    end

    describe "GET cart_items_count" do
      it "renders the Inertia page" do
        get :cart_items_count

        expect(inertia.component).to eq("Products/CartItemsCount")
        expect(inertia.props[:cart]).to be_nil

        html = Nokogiri::HTML.parse(response.body)
        [
          "gr:google_analytics:enabled",
          "gr:fb_pixel:enabled",
        ].each do |property|
          expect(html.xpath("//meta[@property='#{property}']/@content").text).to eq("false")
        end
      end

      it "returns cart props when the user has a cart with items" do
        sign_in @user
        product = create(:product)
        cart = create(:cart, user: @user, email: @user.email)
        create(:cart_product, cart:, product:)

        get :cart_items_count

        expect(inertia.component).to eq("Products/CartItemsCount")
        expect(inertia.props[:cart]).to match(
          email: @user.email,
          returnUrl: "",
          rejectPppDiscount: false,
          discountCodes: [],
          items: [
            a_hash_including(
              product: a_hash_including(permalink: product.unique_permalink),
              quantity: 1,
            ),
          ],
        )
      end
    end

    describe "POST increment_views" do
      before do
        @product = create(:product)
        @request.env["HTTP_USER_AGENT"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_7_3) AppleWebKit/535.19 (KHTML, like Gecko) Chrome/18.0.1025.165 Safari/535.19"
        ElasticsearchIndexerWorker.jobs.clear
      end

      shared_examples "records page view" do
        it "does record page view" do
          post :increment_views, params: { id: @product.to_param }
          expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", hash_including("class_name" => "ProductPageView"))
        end
      end

      context "with a logged out visitor" do
        before do
          sign_out @user
        end

        include_examples "records page view"
      end

      context "with a logged out user" do
        include_examples "records page view"
      end

      context "when requests come from custom domains" do
        before do
          @request.host = "www.example1.com"
          create(:custom_domain, domain: "www.example1.com", user: nil, product: create(:product))
        end

        include_examples "records page view"
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

      it "does not record page view for the seller of the product" do
        allow(controller).to receive(:current_user).and_return(@product.user)
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      it "does not record page view for an admin user" do
        allow(controller).to receive(:current_user).and_return(create(:admin_user))
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      context "with user signed in as admin for seller" do
        include_context "with user signed in as admin for seller" do
          let(:seller) { @product.user }
        end

        it "does not record page view" do
          post :increment_views, params: { id: @product.to_param }

          expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
        end
      end

      it "does not record page view for bots" do
        @request.env["HTTP_USER_AGENT"] = "EventMachine HttpClient"
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end

      it "does not record page view for an admin becoming user" do
        sign_in create(:admin_user)
        controller.impersonate_user(@user)
        post :increment_views, params: { id: @product.to_param }

        expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)
      end
    end

    describe "POST track_user_action" do
      context "with signed in user" do
        before do
          sign_in @user
        end

        shared_examples "creates an event" do
          it "writes the event to the events table" do
            post :track_user_action, params: { id: product.to_param, event_name: "link_view" }
            event = Event.last!
            expect(event.event_name).to eq "link_view"
            expect(event.link_id).to eq product.id
          end
        end

        context "with a product" do
          let(:product) { create(:product) }

          include_examples "creates an event"

          context "when requests come from custom domains" do
            before do
              @request.host = "www.example1.com"
              create(:custom_domain, domain: "www.example1.com", user: nil, product:)
            end

            include_examples "creates an event"
          end
        end
      end
    end

    describe "create_purchase_event" do
      it "creates a purchase event" do
        cookies[:_gumroad_guid] = "blahblahblah"
        @product = create(:product)
        purchase = create(:purchase, link: @product)
        controller.create_purchase_event(purchase)
        expect(Event.order(:id).last.event_name).to eq "purchase"
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
