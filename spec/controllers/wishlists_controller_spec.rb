# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe WishlistsController, type: :controller, inertia: true do
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

    it "creates a wishlist and redirects with notice" do
      expect { post :create }.to change(Wishlist, :count).by(1)
      expect(response).to redirect_to(wishlists_path)
      expect(flash[:notice]).to eq("Wishlist created!")
    end
  end

  describe "GET show" do
    it "renders Wishlists/Show with Inertia and public props" do
      request.host = URI.parse(user.subdomain_with_protocol).host
      get :show, params: { id: wishlist.url_slug }

      expect(response).to be_successful
      expect(inertia.component).to eq("Wishlists/Show")
      expect(inertia.props[:id]).to eq(wishlist.external_id)
      expect(inertia.props[:name]).to eq(wishlist.name)
      expect(inertia.props[:layout]).to be_nil
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
