# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe WishlistsController, type: :controller, inertia: true do
  render_views

  let(:user) { create(:user) }
  let(:wishlist) { create(:wishlist, user:) }

  describe "GET index" do
    before do
      sign_in(user)
      wishlist
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Wishlist }
    end

    context "when html is requested" do
      it "renders Wishlists/Index with Inertia and non-deleted wishlists for the current seller" do
        wishlist.mark_deleted!
        alive_wishlist = create(:wishlist, user:)
        create(:wishlist)

        get :index

        expect(response).to be_successful
        expect(inertia.component).to eq("Wishlists/Index")
        expect(inertia.props[:wishlists]).to contain_exactly(a_hash_including(id: alive_wishlist.external_id))
      end
    end

    context "when json is requested" do
      it "returns wishlists with the given ids" do
        wishlist2 = create(:wishlist, user:)
        create(:wishlist, user:)

        get :index, format: :json, params: { ids: [wishlist.external_id, wishlist2.external_id] }

        expect(response).to be_successful
        expect(response.parsed_body).to eq(WishlistPresenter.cards_props(wishlists: Wishlist.where(id: [wishlist.id, wishlist2.id]), pundit_user: controller.pundit_user, layout: Product::Layout::PROFILE).as_json)
      end
    end
  end

  describe "POST create" do
    before do
      sign_in user
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Wishlist }
    end

    it "creates a wishlist with the given name" do
      expect { post :create, format: :json, params: { wishlist: { name: "My Favorite Products" } } }
        .to change(Wishlist, :count).by(1)

      expect(Wishlist.last).to have_attributes(name: "My Favorite Products", user:)
      expect(response.parsed_body).to eq(
        "wishlist" => {
          "id" => Wishlist.last.external_id,
          "name" => "My Favorite Products"
        }
      )
    end

    it "returns an error when name is blank" do
      expect { post :create, format: :json, params: { wishlist: { name: "" } } }
        .not_to change(Wishlist, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "creates a wishlist and redirects with notice" do
      expect { post :create, params: { wishlist: { name: "My Wishlist" } } }
        .to change(Wishlist, :count).by(1)
      expect(response).to redirect_to(wishlists_path)
      expect(flash[:notice]).to eq("Wishlist created!")
    end
  end

  describe "GET show" do
    it "renders Wishlists/Show with Inertia, public props, and favicon meta tags" do
      request.host = URI.parse(user.subdomain_with_protocol).host
      get :show, params: { id: wishlist.url_slug }

      expect(response).to be_successful
      expect(inertia.component).to eq("Wishlists/Show")
      expect(inertia.props[:id]).to eq(wishlist.external_id)
      expect(inertia.props[:name]).to eq(wishlist.name)
      expect(inertia.props[:layout]).to be_nil

      html = Nokogiri::HTML.parse(response.body)
      expect(html.xpath("//link[@rel='shortcut icon']/@href").text).to include(user.avatar_url)
      # apple-touch-icon now mirrors the shortcut icon (gp#1966: it previously stayed blank
      # here while the seller's own product/subscribe pages already set it consistently).
      expect(html.xpath("//link[@rel='apple-touch-icon']/@href").text).to include(user.avatar_url)
    end

    context "when layout is profile" do
      it "includes creator_profile in props" do
        request.host = URI.parse(user.subdomain_with_protocol).host
        get :show, params: { id: wishlist.url_slug, layout: "profile" }

        expect(response).to be_successful
        expect(inertia.component).to eq("Wishlists/Show")
        expect(inertia.props[:layout]).to eq("profile")
        expect(inertia.props[:creator_profile]).to be_present
      end
    end

    context "when layout is discover" do
      it "includes taxonomies_for_nav in props" do
        request.host = URI.parse(user.subdomain_with_protocol).host
        get :show, params: { id: wishlist.url_slug, layout: "discover" }

        expect(response).to be_successful
        expect(inertia.component).to eq("Wishlists/Show")
        expect(inertia.props[:layout]).to eq("discover")
        expect(inertia.props).to have_key(:taxonomies_for_nav)
      end
    end

    context "when the wishlist is deleted" do
      before { wishlist.mark_deleted! }

      it "returns 404" do
        request.host = URI.parse(user.subdomain_with_protocol).host
        expect { get :show, params: { id: wishlist.url_slug } }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end

    describe "SEO meta tags" do
      before { request.host = URI.parse(user.subdomain_with_protocol).host }

      let(:canonical_url) { Rails.application.routes.url_helpers.wishlist_url(wishlist.url_slug, host: user.subdomain_with_protocol) }

      def parsed_head
        Nokogiri::HTML.parse(response.body)
      end

      it "renders a unique title, meta description, and canonical URL" do
        wishlist.update!(name: "Design Goodies", description: "My favorite design tools")

        get :show, params: { id: wishlist.url_slug }

        html = parsed_head
        expect(html.at_css("title").text).to eq("Design Goodies — curated digital products | Gumroad")
        expect(html.at_css("meta[name='description']")["content"]).to eq("My favorite design tools")
        expect(html.at_css("link[rel='canonical']")["href"]).to eq(canonical_url)
      end

      it "falls back to a generated description when the wishlist has none" do
        wishlist.update!(name: "Design Goodies", description: nil)
        create_list(:wishlist_product, 2, wishlist:)

        get :show, params: { id: wishlist.url_slug }

        expect(parsed_head.at_css("meta[name='description']")["content"])
          .to eq("Design Goodies — a wishlist of 2 digital products curated by #{user.name_or_username} on Gumroad.")
      end

      context "when the wishlist passes the quality gate" do
        before do
          wishlist.update!(name: "Design Goodies")
          create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist:)
        end

        it "sets index,follow and renders ItemList JSON-LD in the initial HTML" do
          get :show, params: { id: wishlist.url_slug }

          html = parsed_head
          expect(html.at_css("meta[name='robots']")["content"]).to eq("index,follow")

          json_ld = JSON.parse(html.at_css("script[type='application/ld+json']").text)
          expect(json_ld["@type"]).to eq("ItemList")
          expect(json_ld["name"]).to eq("Design Goodies")
          expect(json_ld["numberOfItems"]).to eq(3)
          product = wishlist.alive_wishlist_products.first.product
          expect(json_ld["itemListElement"].first).to include(
            "@type" => "ListItem",
            "position" => 1,
            "item" => hash_including(
              "@type" => "Product",
              "name" => product.name,
              "url" => product.long_url,
              "offers" => hash_including("price" => product.price_cents / 100.0, "priceCurrency" => "USD")
            )
          )
        end
      end

      context "when the wishlist has fewer than the minimum products" do
        before do
          wishlist.update!(name: "Design Goodies")
          create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS - 1, wishlist:)
        end

        it "sets noindex and renders no JSON-LD" do
          get :show, params: { id: wishlist.url_slug }

          html = parsed_head
          expect(html.at_css("meta[name='robots']")["content"]).to eq("noindex")
          expect(html.at_css("script[type='application/ld+json']")).to be_nil
        end
      end

      context "when the wishlist is opted out of Discover" do
        before do
          wishlist.update!(name: "Design Goodies", discover_opted_out: true)
          create_list(:wishlist_product, Wishlist::MINIMUM_SEO_INDEXABLE_PRODUCTS, wishlist:)
        end

        it "sets noindex" do
          get :show, params: { id: wishlist.url_slug }

          expect(parsed_head.at_css("meta[name='robots']")["content"]).to eq("noindex")
        end
      end
    end
  end

  describe "PUT update" do
    before do
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { Wishlist }
      let(:request_params) { { id: wishlist.external_id, wishlist: { name: "New Name" } } }
    end

    it "updates the wishlist name and description" do
      put :update, params: { id: wishlist.external_id, wishlist: { name: "New Name", description: "New Description" } }

      expect(response).to redirect_to(wishlists_path)
      expect(flash[:notice]).to eq("Wishlist updated!")
      expect(wishlist.reload.name).to eq "New Name"
      expect(wishlist.description).to eq "New Description"
    end

    it "renders validation errors" do
      expect do
        put :update, params: { id: wishlist.external_id, wishlist: { name: "" } }
      end.not_to change { wishlist.reload.name }

      expect(response).to redirect_to(wishlists_path)
      expect(response).to have_http_status(:see_other)
    end
  end

  describe "DELETE destroy" do
    before do
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { wishlist }
      let(:request_params) { { id: wishlist.external_id } }
    end

    it "marks the wishlist and followers as deleted" do
      wishlist_follower = create(:wishlist_follower, wishlist:)

      delete :destroy, params: { id: wishlist.external_id }

      expect(response).to redirect_to(wishlists_path)
      expect(flash[:notice]).to eq("Wishlist deleted!")
      expect(wishlist.reload).to be_deleted
      expect(wishlist_follower.reload).to be_deleted
    end
  end
end
