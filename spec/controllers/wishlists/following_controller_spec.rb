# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Wishlists::FollowingController do
  render_views

  let(:user) { create(:user) }

  describe "GET index" do
    before do
      sign_in(user)
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Wishlist }
    end

    it "renders wishlists the seller is currently following" do
      create(:wishlist, user: user)

      following_wishlist = create(:wishlist)
      create(:wishlist_follower, follower_user: user, wishlist: following_wishlist)

      deleted_follower = create(:wishlist)
      create(:wishlist_follower, follower_user: user, wishlist: deleted_follower, deleted_at: Time.current)

      get :index

      expect(response).to be_successful
      expect(assigns(:wishlists_props)).to contain_exactly(a_hash_including(id: following_wishlist.external_id))
    end

    context "when the feature flag is off" do
      before { Feature.deactivate(:follow_wishlists) }

      it "returns 404" do
        expect { get :index }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
