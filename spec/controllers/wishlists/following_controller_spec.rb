require "spec_helper"
require "inertia_rails/rspec"
require "shared_examples/authorize_called"

describe Wishlists::FollowingController, inertia: true do
  let(:user) { create(:user) }

  let(:follow_wishlist_inactive) { false }

  describe "GET index" do
    before do
      allow(Feature).to receive(:inactive?).and_call_original
      allow(Feature).to receive(:inactive?).with(:follow_wishlists, user).and_return(follow_wishlist_inactive)
      allow(Feature).to receive(:active?).and_call_original
      allow(Feature).to receive(:active?).with(:reviews_page, user).and_return(true)

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
      expect(inertia.component).to eq("Wishlists/Following")
      expect(inertia.props[:wishlists]).to contain_exactly(a_hash_including(id: following_wishlist.external_id))
      expect(inertia.props[:wishlists]).not_to include(a_hash_including(id: deleted_follower.external_id))
      expect(inertia.props[:reviews_page_enabled]).to eq(true)
    end

    context "when the feature flag is off" do
      let(:follow_wishlist_inactive) { true }

      it "returns 404" do
        expect { get :index }.to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
