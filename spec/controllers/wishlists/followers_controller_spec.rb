# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Wishlists::FollowersController do
  let(:user) { create(:user) }
  let(:wishlist) { create(:wishlist) }

  before do
    sign_in(user)
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { WishlistFollower }
      let(:request_params) { { wishlist_id: wishlist.external_id } }
    end

    it "follows the wishlist" do
      expect do
        post :create, params: { wishlist_id: wishlist.external_id }
      end.to change(wishlist.wishlist_followers, :count).from(0).to(1)

      expect(wishlist.wishlist_followers.first.follower_user).to eq(user)
    end

    it "returns an error if the follower is invalid" do
      create(:wishlist_follower, wishlist:, follower_user: user)

      expect do
        post :create, params: { wishlist_id: wishlist.external_id }
      end.not_to change(WishlistFollower, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("Follower user is already following this wishlist.")
    end

    context "when the feature flag is off" do
      before { Feature.deactivate(:follow_wishlists) }

      it "returns 404" do
        expect { post :create, params: { wishlist_id: wishlist.external_id } }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end

  describe "DELETE destroy" do
    let!(:wishlist_follower) { create(:wishlist_follower, wishlist:, follower_user: user) }

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { wishlist_follower }
      let(:request_params) { { wishlist_id: wishlist.external_id } }
    end

    it "deletes the follower" do
      delete :destroy, params: { wishlist_id: wishlist.external_id }

      expect(wishlist_follower.reload).to be_deleted
    end

    it "returns 404 if the user is not following" do
      wishlist_follower.mark_deleted!

      expect do
        delete :destroy, params: { wishlist_id: wishlist.external_id }
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end

    context "when the feature flag is off" do
      before { Feature.deactivate(:follow_wishlists) }

      it "returns 404" do
        expect { delete :destroy, params: { wishlist_id: wishlist.external_id } }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end

  describe "GET unsubscribe" do
    let!(:wishlist_follower) { create(:wishlist_follower, wishlist:, follower_user: user) }

    it "deletes the follower and redirects to the wishlist" do
      get :unsubscribe, params: { wishlist_id: wishlist.external_id, follower_id: wishlist_follower.external_id }

      expect(response).to redirect_to(wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol))
      expect(wishlist_follower.reload).to be_deleted
    end
  end
end
