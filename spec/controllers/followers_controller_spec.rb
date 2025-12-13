# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe FollowersController, inertia: true do
  render_views

  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "GET index" do
      it "returns successful response with Inertia page data" do
        followers = create_list(:follower, 20, user: seller) do |follower, index|
          follower.update!(confirmed_at: Time.current - index.days)
        end
        create(:follower, user: seller, confirmed_at: Time.current - 30.days)
        create(:follower, user: seller)
        get :index
        expect(response).to be_successful
        expect(inertia.component).to eq("Followers/Index")
        expect(inertia.props).to match(hash_including(
          followers: followers.map { _1.as_json(pundit_user:) },
          per_page: FollowersController::FOLLOWERS_PER_PAGE,
          total: 21,
        ))
      end
    end

    describe "GET search" do
      context "logged in" do
        it "returns followers with matching emails" do
          follower = create(:active_follower, user: seller)
          get :search, params: { email: follower.email }
          expect(response.parsed_body["paged_followers"][0]["email"]).to eq(follower.email)
        end
      end

      context "logged out" do
        it "redirects user to login" do
          sign_out(seller)
          get :search, params: { email: "sample" }
          expect(response).to redirect_to(login_path(next: "/followers/search?email=sample"))
        end
      end
    end
  end

  context "within consumer area" do
    describe "GET new" do
      before do
        @user = create(:user, username: "dude")
        get :new, params: { username: @user.username }
      end

      it "redirects to user profile" do
        expect(response).to redirect_to(@user.profile_url)
      end
    end

    describe "POST create" do
      it "creates a follower object" do
        post :create, params: { email: "follower@example.com", seller_id: seller.external_id }

        follower = Follower.last
        expect(follower.email).to eq "follower@example.com"
        expect(follower.user).to eq seller
      end

      it "returns json success with a message" do
        post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["message"]).to eq("Check your inbox to confirm your follow request.")
      end

      it "returns json error when email is invalid" do
        post :create, params: { email: "invalid email", seller_id: seller.external_id }
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Email invalid.")
      end

      it "uncancels if follow object exists" do
        follower = create(:deleted_follower, email: "follower@example.com", followed_id: seller.id)
        expect { post :create, params: { email: "follower@example.com", seller_id: seller.external_id } }.to change {
          follower.reload.deleted?
        }.from(true).to(false)
      end

      describe "logged in" do
        before do
          @buyer = create(:user)
          @params = { seller_id: seller.external_id, email: @buyer.email }
          sign_in @buyer
        end

        it "returns json success with a message" do
          post :create, params: @params
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["message"]).to eq("You are now following #{seller.name_or_username}!")
        end

        it "creates a new follower row" do
          expect { post :create, params: @params }.to change {
            Follower.count
          }.by(1)
        end
      end

      describe "create follow object with email, create a user with same email, and log in" do
        it "follow should update the existing follower and not create another one or throw an exception" do
          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }

          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["message"]).to eq("Check your inbox to confirm your follow request.")

          follower = Follower.last
          expect(follower.email).to eq "follower@example.com"
          expect(follower.user).to eq seller

          new_user = create(:user, email: "follower@example.com")
          sign_in new_user

          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          expect(response.parsed_body["success"]).to be(true)
          expect(response.parsed_body["message"]).to eq("You are now following #{seller.name_or_username}!")

          expect(Follower.count).to be 1
          expect(Follower.last.follower_user_id).to be new_user.id
        end
      end
    end

    describe "POST confirm" do
      let(:unconfirmed_follower) { create(:follower, user: seller) }

      it "confirms the follow" do
        post :confirm, params: { id: unconfirmed_follower.external_id }
        expect(response).to redirect_to(seller.profile_url)
        expect(unconfirmed_follower.reload.confirmed_at).to_not eq(nil)
      end

      it "returns 404 when follower is invalid" do
        expect { post :confirm, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
      end

      it "returns 404 when seller is inactive" do
        seller.deactivate!
        expect do
          post :confirm, params: { id: unconfirmed_follower.external_id }
        end.to raise_error(ActionController::RoutingError)
      end
    end

    describe "POST from_embed_form" do
      it "creates a follower object" do
        post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
        follower = Follower.last
        expect(follower.email).to eq "follower@example.com"
        expect(follower.user).to eq seller
      end

      it "shows proper success messaging" do
        post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
        expect(response.body).to match("Followed!")
      end

      it "redirects to follow page on failure with proper messaging" do
        post :from_embed_form, params: { email: "exampleexample.com", seller_id: seller.external_id }
        expect(response).to redirect_to(seller.profile_url)
        expect(flash[:warning]).to include("try to follow the creator again")
      end

      context "when a user is already following the creator using the same email" do
        let(:following_user) { create(:user, email: "follower@example.com") }
        let!(:following_relationship) { create(:active_follower, user: seller, email: following_user.email, follower_user_id: following_user.id, source: Follower::From::PROFILE_PAGE) }

        it "does not create a new follower object; preserves the existing following relationship" do
          expect do
            post :from_embed_form, params: { email: following_user.email, seller_id: seller.external_id }
          end.not_to change { Follower.count }

          expect(following_relationship.follower_user_id).to eq(following_user.id)
          expect(response.body).to match("Followed!")
        end
      end
    end

    describe "POST cancel" do
      it "cancels the follow" do
        follower = create(:follower)
        expect { post :cancel, params: { id: follower.external_id } }.to change {
          follower.reload.deleted?
        }.from(false).to(true)
      end

      it "returns 404 when follower is invalid" do
        expect { post :cancel, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
