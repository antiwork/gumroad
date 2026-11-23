# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::UsersController do
  before do
    @user = create(:user, username: "dude", email: "abc@def.ghi")
    @product = create(:product, user: @user)
    @purchase = create(:purchase, link: @product, seller: @user)
    @app = create(:oauth_application, owner: create(:user))
  end

  describe "GET 'show'" do
    before do
      @action = :show
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the user without email" do
        get @action, params: @params
        expect(response.parsed_body).to eq("success" => true,
                                           "user" => @user.as_json(api_scopes: ["view_public"]))
        expect(response.parsed_body["user"]["url"]).to be_present
        expect(response.parsed_body["user"]["email"]).to_not be_present
      end

      it "shows data if show_ifttt" do
        get @action, params: @params.merge(is_ifttt: true)
        @user.name = @user.email if @user.name.blank?
        expect(response.parsed_body).to eq("success" => true,
                                           "data" => @user.as_json(api_scopes: ["view_public"]))
      end
    end

    it "includes the user's email when logged in with a token which contains api_scope 'view_sales'" do
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
      @params.merge!(access_token: @token.token)
      get @action, params: @params
      expect(response.parsed_body).to eq("success" => true,
                                         "user" => @user.as_json(api_scopes: ["view_sales"]))
      expect(response.parsed_body["user"]["email"]).to eq("abc@def.ghi")
    end

    it "includes user's email and profile_url with 'view_profile' scope" do
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

    it "grants full access with the account scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "account")
      get @action, params: { access_token: token.token }
      expect(response).to be_successful
      expect(response.parsed_body["user"]["email"]).to eq(@user.form_email)
      expect(response.parsed_body["user"]["display_name"]).to be_present
    end
  end

  describe "PUT 'update'" do
    before do
      @action = :update
      @params = { name: "Jane Seller", bio: "I make great things." }
    end

    it_behaves_like "authorized oauth v1 api method"

    it "rejects a token without the edit_profile scope" do
      token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_profile")
      put @action, params: @params.merge(access_token: token.token)
      expect(response.status).to eq(403)
      expect(response.body.strip).to be_empty
    end

    describe "when logged in with edit_profile scope" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "edit_profile")
        @params.merge!(access_token: @token.token)
      end

      it "updates the seller name and bio" do
        put @action, params: @params

        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.reload.name).to eq("Jane Seller")
        expect(@user.bio).to eq("I make great things.")
      end

      it "rejects the update when the seller's email is unconfirmed" do
        @user.update_columns(confirmed_at: nil)

        put @action, params: @params

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("confirm your email address")
        expect(@user.reload.name).to_not eq("Jane Seller")
      end

      it "updates only the provided attribute" do
        @user.update!(name: "Original", bio: "Original bio")

        put @action, params: { access_token: @token.token, bio: "Updated bio" }

        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.reload.name).to eq("Original")
        expect(@user.bio).to eq("Updated bio")
      end

      it "sets the home page SEO title and description" do
        put @action, params: { access_token: @token.token, seo_title: "Hand-lettered posters", seo_description: "Posters and prints." }

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["user"]).to include("seo_title" => "Hand-lettered posters", "seo_description" => "Posters and prints.")
        expect(@user.seller_profile.reload.seo_title).to eq("Hand-lettered posters")
        expect(@user.seller_profile.seo_description).to eq("Posters and prints.")
      end

      it "clears an SEO field sent blank and leaves an omitted one alone" do
        @user.seller_profile.update!(seo_title: "Old title", seo_description: "Old description")

        put @action, params: { access_token: @token.token, seo_title: "" }

        expect(@user.seller_profile.reload.seo_title).to be_nil
        expect(@user.seller_profile.seo_description).to eq("Old description")
      end

      it "saves nothing when an SEO field is over the limit" do
        put @action, params: @params.merge(seo_title: "a" * (Page::MAX_SEO_TITLE_LENGTH + 1))

        expect(response.parsed_body["success"]).to eq(false)
        expect(@user.reload.name).not_to eq("Jane Seller")
        expect(SellerProfile.where(seller: @user).pluck(:seo_title)).to all(be_nil)
      end

      it "clears an SEO field sent as null" do
        @user.seller_profile.update!(seo_title: "Old title", seo_description: "Old description")

        put @action, params: { access_token: @token.token, seo_description: nil }, as: :json

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/json")
        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.seller_profile.reload.seo_description).to be_nil
        expect(@user.seller_profile.seo_title).to eq("Old title")
      end

      def reserved_share_image_blob(uploader: @user)
        ActiveStorage::Blob.create_and_upload!(
          io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
          filename: "smilie.png",
          content_type: "image/png",
          metadata: { uploaded_by_user_id: uploader.id }
        )
      end

      it "attaches a storefront share image uploaded as a blob" do
        blob = reserved_share_image_blob

        put @action, params: { access_token: @token.token, share_image_signed_blob_id: blob.signed_id }

        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.reload.seller_profile.share_image).to be_attached
        expect(response.parsed_body["user"]["share_image_url"]).to eq(@user.seller_profile.share_image_url)
      end

      it "removes the share image sent as null" do
        @user.seller_profile.share_image.attach(
          io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
          filename: "smilie.png",
          content_type: "image/png"
        )
        @user.seller_profile.save!

        put @action, params: { access_token: @token.token, share_image_signed_blob_id: nil }, as: :json

        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.reload.seller_profile.share_image).to_not be_attached
      end

      it "leaves the share image alone when the request does not mention it" do
        @user.seller_profile.share_image.attach(
          io: File.open(Rails.root.join("spec", "support", "fixtures", "smilie.png")),
          filename: "smilie.png",
          content_type: "image/png"
        )
        @user.seller_profile.save!

        put @action, params: { access_token: @token.token, seo_title: "Hand-lettered posters" }

        expect(response.parsed_body["success"]).to eq(true)
        expect(@user.reload.seller_profile.share_image).to be_attached
      end

      it "leaves the share image unattached when the name in the same request is rejected" do
        # `attach` writes at once only on a persisted, unchanged profile.
        @user.seller_profile.save!
        blob = reserved_share_image_blob

        put @action, params: { access_token: @token.token, name: "a" * (User::MAX_LENGTH_NAME + 1), share_image_signed_blob_id: blob.signed_id }

        expect(response.parsed_body["success"]).to eq(false)
        expect(@user.reload.seller_profile.share_image).to_not be_attached
      end

      it "rejects a reserved blob whose bytes were never uploaded" do
        blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "cover.png", byte_size: 6, checksum: Digest::MD5.base64digest("pixels"), content_type: "image/png",
          metadata: { uploaded_by_user_id: @user.id }
        )

        put @action, params: { access_token: @token.token, share_image_signed_blob_id: blob.signed_id }

        expect(response.parsed_body).to eq("success" => false, "message" => "The signed_blob_id has no uploaded file yet. Upload the file first, then try again.")
        expect(@user.reload.seller_profile.share_image).to_not be_attached
      end

      it "refuses a blob reserved by another account" do
        blob = reserved_share_image_blob(uploader: create(:user))

        put @action, params: { access_token: @token.token, share_image_signed_blob_id: blob.signed_id }

        expect(response.parsed_body).to eq("success" => false, "message" => "The signed_blob_id must come from a POST /v2/direct_uploads reservation made with this account.")
        expect(@user.reload.seller_profile.share_image).to_not be_attached
      end

      it "rejects an unusable signed blob id without saving the request" do
        put @action, params: { access_token: @token.token, name: "Jane Seller", share_image_signed_blob_id: "not-a-signed-blob" }

        expect(response.parsed_body).to eq("success" => false, "message" => "The signed_blob_id is invalid or expired.")
        expect(@user.reload.name).to_not eq("Jane Seller")
        expect(@user.reload.seller_profile.share_image).to_not be_attached
      end

      it "rejects a non-string share_image_signed_blob_id without saving the request" do
        put @action, params: @params.merge(share_image_signed_blob_id: { "text" => "x" }), as: :json

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq("success" => false, "message" => "share_image_signed_blob_id must be a string.")
        expect(@user.reload.name).to_not eq("Jane Seller")
      end

      %w[seo_title seo_description].each do |key|
        { "a hash" => { "text" => "x" }, "an array" => ["x"], "a number" => 1, "a boolean" => true }.each do |kind, value|
          it "rejects #{kind} as #{key} without saving the name, bio, or SEO fields" do
            @user.seller_profile.update!(seo_title: "Old title", seo_description: "Old description")

            put @action, params: @params.merge(key => value), as: :json

            # The v2 API reports failures in the body with a 200, like every render_response.
            expect(response).to have_http_status(:ok)
            expect(response.media_type).to eq("application/json")
            expect(response.parsed_body).to eq("success" => false, "message" => "#{key} must be a string.")
            expect(@user.reload.name).not_to eq("Jane Seller")
            expect(@user.bio).not_to eq("I make great things.")
            expect(@user.seller_profile.reload.seo_title).to eq("Old title")
            expect(@user.seller_profile.seo_description).to eq("Old description")
          end
        end
      end

      it "returns the updated user in the response" do
        put @action, params: @params

        expect(response.parsed_body).to eq("success" => true,
                                           "user" => @user.reload.as_json(api_scopes: ["edit_profile"]))
      end

      it "does not expose email to a write-only edit_profile token" do
        put @action, params: @params

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["user"]).to_not have_key("email")
      end

      it "returns a validation error when the name is invalid" do
        put @action, params: @params.merge(name: "Jane: Seller")

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to include("colons")
        expect(@user.reload.name).to_not eq("Jane: Seller")
      end

      it "marks the user as a CLI user when requested from the CLI" do
        request.user_agent = "gumroad-cli/1.0"

        put @action, params: @params

        expect(@user.reload.has_used_cli?).to be(true)
      end
    end
  end

  describe "GET 'ifttt_sale_trigger'" do
    before do
      @action = :ifttt_sale_trigger
      @params = {}
    end

    describe "when logged in" do
      before do
        @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public")
        @params.merge!(access_token: @token.token)
      end

      it "shows the most recent sales" do
        get @action, params: @params

        expect(response.parsed_body).to eq(JSON.parse({
          success: true,
          data: @user.sales.successful_or_preorder_authorization_successful.order("created_at DESC").limit(50).map(&:as_json_for_ifttt)
        }.to_json))
      end

      it "shows the most recent sales with after filter" do
        get @action, params: @params.merge!(after: 5.days.ago.to_i.to_s)

        expect(response.parsed_body).to eq(JSON.parse({
          success: true,
          data: @user.sales.successful_or_preorder_authorization_successful
            .where("created_at >= ?", Time.zone.at(@params[:after].to_i)).order("created_at ASC").limit(50).map(&:as_json_for_ifttt)
        }.to_json))
      end

      it "shows the most recent sales with before filter" do
        get @action, params: @params.merge!(before: Time.current.to_i.to_s)

        expect(response.parsed_body).to eq(JSON.parse({
          success: true,
          data: @user.sales.successful_or_preorder_authorization_successful
            .where("created_at <= ?", Time.zone.at(@params[:before].to_i)).order("created_at DESC").limit(50).map(&:as_json_for_ifttt)
        }.to_json))
      end

      it "eager loads associations for multiple sales" do
        create_list(:purchase, 3, link: @product, seller: @user)

        get @action, params: @params

        expect(response).to be_successful
        expect(response.parsed_body["data"].length).to eq(4)
      end
    end
  end
end
