# frozen_string_literal: true

require "test_helper"
require "shared_examples/authorize_called"

class FollowersControllerTest < ActionController::TestCase
  self.described_class = FollowersController
  tests FollowersController



  context_ FollowersController, inertia: true do
    render_views

    let(:seller) { create(:named_seller) }
    let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  context_ "within seller area" do
      include_context "with user signed in as admin for seller"

  context_ "GET index" do
  test "returns successful response with Inertia page data" do
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
            total_count: 21,
            page: 1,
            has_more: true,
            email: "",
          ))
        end

  test "supports search via email query parameter" do
          create(:follower, user: seller, email: "test@example.com", confirmed_at: Time.current)
          create(:follower, user: seller, email: "other@example.com", confirmed_at: Time.current)
          get :index, params: { email: "test" }
          expect(response).to be_successful
          expect(inertia.component).to eq("Followers/Index")
          expect(inertia.props).to match(hash_including(
            total_count: 2,
            email: "test",
          ))
          expect(inertia.props[:followers].length).to eq(1)
          expect(inertia.props[:followers].first).to match(hash_including(email: "test@example.com"))
        end

  test "supports pagination via page query parameter" do
          create_list(:follower, 25, user: seller) do |follower|
            follower.update!(confirmed_at: Time.current)
          end
          get :index, params: { page: 2 }
          expect(response).to be_successful
          expect(inertia.props[:page]).to eq(2)
          expect(inertia.props[:followers].length).to eq(5)
          expect(inertia.props[:has_more]).to be(false)
        end

  test "combines search and pagination" do
          create_list(:follower, 25, user: seller) do |follower, index|
            follower.update!(email: "test#{index}@example.com", confirmed_at: Time.current)
          end
          get :index, params: { email: "test", page: 2 }
          expect(response).to be_successful
          expect(inertia.props[:email]).to eq("test")
          expect(inertia.props[:page]).to eq(2)
          expect(inertia.props[:total_count]).to eq(25)
        end
      end

  context_ "DELETE destroy" do
        let(:follower) { create(:active_follower, user: seller) }

  test "marks follower as deleted and redirects with notice" do
          delete :destroy, params: { id: follower.external_id }
          expect(response).to redirect_to(followers_path)
          expect(flash[:notice]).to eq("Follower removed!")
          expect(follower.reload.deleted?).to be(true)
        end

  test "returns 404 when follower is invalid" do
          expect { delete :destroy, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
        end
      end
    end

  context_ "within consumer area" do
  context_ "GET new" do
        before do
          @user = create(:user, username: "dude")
          get :new, params: { username: @user.username }
        end

  test "redirects to user profile" do
          expect(response).to redirect_to(@user.profile_url)
        end
      end

  context_ "POST create" do
  test "redirects to subscribe page with notice on success" do
          post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(response).to have_http_status(:see_other)
          expect(flash[:notice]).to eq("Check your inbox to confirm your follow request.")

          follower = Follower.last
          expect(follower.email).to eq "follower@example.com"
          expect(follower.user).to eq seller
        end

  test "redirects to subscribe page with alert when email is invalid" do
          post :create, params: { email: "invalid email", seller_id: seller.external_id }
          expect(response).to redirect_to(custom_domain_subscribe_path)
          expect(flash[:alert]).to include("Email invalid")
        end

  test "uncancels if follow object exists" do
          follower = create(:deleted_follower, email: "follower@example.com", followed_id: seller.id)
          expect { post :create, params: { email: "follower@example.com", seller_id: seller.external_id } }.to change {
            follower.reload.deleted?
          }.from(true).to(false)
        end

  context_ "logged in" do
          before do
            @buyer = create(:user)
            @params = { seller_id: seller.external_id, email: @buyer.email }
            sign_in @buyer
          end

  test "redirects to subscribe page with notice on success" do
            post :create, params: @params
            expect(response).to redirect_to(custom_domain_subscribe_path)
            expect(response).to have_http_status(:see_other)
            expect(flash[:notice]).to eq("You are now following #{seller.name_or_username}!")
          end

  test "creates a new follower row" do
            expect { post :create, params: @params }.to change {
              Follower.count
            }.by(1)
          end
        end

  context_ "create follow object with email, create a user with same email, and log in" do
  test "follow should update the existing follower and not create another one or throw an exception" do
            post :create, params: { email: "follower@example.com", seller_id: seller.external_id }

            expect(response).to redirect_to(custom_domain_subscribe_path)
            expect(response).to have_http_status(:see_other)
            expect(flash[:notice]).to eq("Check your inbox to confirm your follow request.")

            follower = Follower.last
            expect(follower.email).to eq "follower@example.com"
            expect(follower.user).to eq seller

            new_user = create(:user, email: "follower@example.com")
            sign_in new_user

            post :create, params: { email: "follower@example.com", seller_id: seller.external_id }
            expect(response).to redirect_to(custom_domain_subscribe_path)
            expect(response).to have_http_status(:see_other)
            expect(flash[:notice]).to eq("You are now following #{seller.name_or_username}!")

            expect(Follower.count).to be 1
            expect(Follower.last.follower_user_id).to be new_user.id
          end
        end
      end

  context_ "GET confirm" do
        let(:unconfirmed_follower) { create(:follower, user: seller) }

  test "confirms the follow" do
          get :confirm, params: { id: unconfirmed_follower.external_id }
          expect(response).to redirect_to(seller.profile_url)
          expect(unconfirmed_follower.reload.confirmed_at).not_to eq(nil)
        end

  test "returns 404 when follower is invalid" do
          expect { get :confirm, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
        end

  test "returns 404 when seller is inactive" do
          seller.deactivate!
          expect do
            get :confirm, params: { id: unconfirmed_follower.external_id }
          end.to raise_error(ActionController::RoutingError)
        end
      end

  context_ "POST from_embed_form" do
  test "creates a follower object" do
          post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
          follower = Follower.last
          expect(follower.email).to eq "follower@example.com"
          expect(follower.user).to eq seller
        end

  test "renders Inertia page with success message" do
          post :from_embed_form, params: { email: "follower@example.com", seller_id: seller.external_id }
          expect(response).to be_successful
          expect(inertia.component).to eq("Followers/FromEmbedForm")
          expect(inertia.props[:success]).to be(true)
          expect(inertia.props[:message]).to eq("Check your inbox to confirm your follow request.")
        end

  test "redirects to seller profile with flash warning on failure" do
          post :from_embed_form, params: { email: "exampleexample.com", seller_id: seller.external_id }
          expect(response).to redirect_to(seller.profile_url)
          expect(flash[:warning]).to be_present
          expect(flash[:warning]).to include("Email invalid")
        end

  context_ "when a user is already following the creator using the same email" do
          let(:following_user) { create(:user, email: "follower@example.com") }
          let!(:following_relationship) { create(:active_follower, user: seller, email: following_user.email, follower_user_id: following_user.id, source: Follower::From::PROFILE_PAGE) }

  test "does not create a new follower object; preserves the existing following relationship" do
            expect do
              post :from_embed_form, params: { email: following_user.email, seller_id: seller.external_id }
            end.not_to change { Follower.count }

            expect(following_relationship.follower_user_id).to eq(following_user.id)
            expect(response).to be_successful
            expect(inertia.component).to eq("Followers/FromEmbedForm")
            expect(inertia.props[:success]).to be(true)
            expect(inertia.props[:message]).to eq("You are now following #{seller.name_or_username}!")
          end
        end
      end

  context_ "GET cancel" do
  test "cancels the follow and renders Inertia page" do
          follower = create(:follower)
          expect { get :cancel, params: { id: follower.external_id } }.to change {
            follower.reload.deleted?
          }.from(false).to(true)
          expect(response).to be_successful
          expect(inertia.component).to eq("Followers/Cancel")
        end

  test "returns 404 when follower is invalid" do
          expect { get :cancel, params: { id: "invalid follower" } }.to raise_error(ActionController::RoutingError)
        end
      end
    end
  end
end
