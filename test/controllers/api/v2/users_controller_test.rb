# frozen_string_literal: true

require "test_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

class ApiV2UsersControllerTest < ActionController::TestCase
  self.described_class = Api::V2::UsersController
  tests Api::V2::UsersController



  context_ Api::V2::UsersController do
    before do
      @user = create(:user, username: "dude", email: "abc@def.ghi")
      @product = create(:product, user: @user)
      @purchase = create(:purchase, link: @product, seller: @user)
      @app = create(:oauth_application, owner: create(:user))
    end

  context_ "GET 'show'" do
      before do
        @action = :show
        @params = {}
      end

      it_behaves_like "authorized oauth v1 api method"

  context_ "when logged in" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
          @params.merge!(access_token: @token.token)
        end

  test "shows the user without email" do
          get @action, params: @params
          expect(response.parsed_body).to eq("success" => true,
                                             "user" => @user.as_json(api_scopes: ["view_public"]))
          expect(response.parsed_body["user"]["url"]).to be_present
          expect(response.parsed_body["user"]["email"]).not_to be_present
        end

  test "shows data if show_ifttt" do
          get @action, params: @params.merge(is_ifttt: true)
          @user.name = @user.email if @user.name.blank?
          expect(response.parsed_body).to eq("success" => true,
                                             "data" => @user.as_json(api_scopes: ["view_public"]))
        end
      end

  test "includes the user's email when logged in with a token which contains api_scope 'view_sales'" do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
        @params.merge!(access_token: @token.token)
        get @action, params: @params
        expect(response.parsed_body).to eq("success" => true,
                                           "user" => @user.as_json(api_scopes: ["view_sales"]))
        expect(response.parsed_body["user"]["email"]).to eq("abc@def.ghi")
      end

  test "includes user's email and profile_url with 'view_profile' scope" do
        user = create(:named_user, :with_avatar)
        token = create("doorkeeper/access_token", application: @app, resource_owner_id: user.id, scopes: "view_profile")

        get @action, params: @params.merge(access_token: token.token)

        expect(response.parsed_body).to eq("success" => true,
                                           "user" => user.as_json(api_scopes: ["view_profile"]))

        expect(response.parsed_body["user"]["id"]).to be_present
        expect(response.parsed_body["user"]["url"]).to be_present
        expect(response.parsed_body["user"]["email"]).to be_present
        expect(response.parsed_body["user"]["profile_url"]).to be_present
        expect(response.parsed_body["user"]["profile_picture_url"]).to be_present
        expect(response.parsed_body["user"]["display_name"]).to be_present
      end

  test "grants full access with the account scope" do
        token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
        get @action, params: { access_token: token.token }
        expect(response).to be_successful
        expect(response.parsed_body["user"]["email"]).to eq(@user.form_email)
        expect(response.parsed_body["user"]["display_name"]).to be_present
      end
    end

  context_ "GET 'ifttt_sale_trigger'" do
      before do
        @action = :ifttt_sale_trigger
        @params = {}
      end

  context_ "when logged in" do
        before do
          @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
          @params.merge!(access_token: @token.token)
        end

  test "shows the most recent sales" do
          get @action, params: @params

          expect(response.parsed_body).to eq(JSON.parse({
            success: true,
            data: @user.sales.successful_or_preorder_authorization_successful.order("created_at DESC").limit(50).map(&:as_json_for_ifttt)
          }.to_json))
        end

  test "shows the most recent sales with after filter" do
          get @action, params: @params.merge!(after: 5.days.ago.to_i.to_s)

          expect(response.parsed_body).to eq(JSON.parse({
            success: true,
            data: @user.sales.successful_or_preorder_authorization_successful
              .where("created_at >= ?", Time.zone.at(@params[:after].to_i)).order("created_at ASC").limit(50).map(&:as_json_for_ifttt)
          }.to_json))
        end

  test "shows the most recent sales with before filter" do
          get @action, params: @params.merge!(before: Time.current.to_i.to_s)

          expect(response.parsed_body).to eq(JSON.parse({
            success: true,
            data: @user.sales.successful_or_preorder_authorization_successful
              .where("created_at <= ?", Time.zone.at(@params[:before].to_i)).order("created_at DESC").limit(50).map(&:as_json_for_ifttt)
          }.to_json))
        end

  test "eager loads associations for multiple sales" do
          create_list(:purchase, 3, link: @product, seller: @user)

          get @action, params: @params

          expect(response).to be_successful
          expect(response.parsed_body["data"].length).to eq(4)
        end
      end
    end
  end
end
