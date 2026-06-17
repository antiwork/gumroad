# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::InstallmentsController do
  before do
    @user = create(:user, email: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_access_token(scopes)
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes:)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create_access_token("view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns the seller's alive non-workflow installments" do
        draft = create(:audience_installment, seller: @user, created_at: 3.minutes.ago)
        published = create(:audience_installment, :published, seller: @user, created_at: 2.minutes.ago)
        scheduled = create(
          :scheduled_installment,
          seller: @user,
          link: nil,
          installment_type: Installment::AUDIENCE_TYPE,
          created_at: 1.minute.ago
        )
        create(:audience_installment, seller: @user, deleted_at: Time.current)
        create(:workflow_installment, seller: @user, link: create(:product, user: @user))
        create(:audience_installment, seller: create(:user))

        get @action, params: @params

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["installments"].map { _1["id"] })
          .to eq([scheduled, published, draft].map(&:external_id))
      end

      it "filters installments by type" do
        draft = create(:audience_installment, seller: @user, created_at: 3.minutes.ago)
        published = create(:audience_installment, :published, seller: @user, created_at: 2.minutes.ago)
        scheduled = create(
          :scheduled_installment,
          seller: @user,
          link: nil,
          installment_type: Installment::AUDIENCE_TYPE,
          created_at: 1.minute.ago
        )

        get @action, params: @params.merge(type: Installment::PUBLISHED)
        expect(response.parsed_body["installments"].map { _1["id"] }).to eq([published.external_id])

        get @action, params: @params.merge(type: Installment::SCHEDULED)
        expect(response.parsed_body["installments"].map { _1["id"] }).to eq([scheduled.external_id])

        get @action, params: @params.merge(type: Installment::DRAFT)
        expect(response.parsed_body["installments"].map { _1["id"] }).to eq([draft.external_id])
      end

      it "paginates installments with a page key" do
        per_page = Api::V2::InstallmentsController::RESULTS_PER_PAGE
        installments = (0..per_page).map do |index|
          create(:audience_installment, seller: @user, created_at: (per_page - index).minutes.ago)
        end
        expected_installments = installments.sort_by { |installment| [installment.created_at, installment.id] }.reverse

        get @action, params: @params

        expect(response.parsed_body["installments"].map { _1["id"] })
          .to eq(expected_installments.first(per_page).map(&:external_id))
        expect(response.parsed_body["next_page_key"]).to be_present
        expect(response.parsed_body["next_page_url"]).to include("/v2/installments")

        get @action, params: @params.merge(page_key: response.parsed_body["next_page_key"])

        expect(response.parsed_body).to eq({
          success: true,
          installments: expected_installments[per_page..].as_json(api_scopes: ["view_public"])
        }.as_json)
      end

      it "returns an empty list for another seller's installments" do
        create(:audience_installment, seller: create(:user))

        get @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          installments: []
        }.as_json)
      end
    end

    it "grants access with the account scope" do
      token = create_access_token("account")
      get @action, params: @params.merge(access_token: token.token)
      expect(response).to be_successful
    end
  end

  describe "GET 'show'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :show
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"

    describe "when logged in with public scope" do
      before do
        @token = create_access_token("view_public")
        @params.merge!(access_token: @token.token)
      end

      it "returns the installment" do
        get @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          installment: @installment.as_json(api_scopes: ["view_public"])
        }.as_json)
      end

      it "does not return another seller's installment" do
        other_installment = create(:audience_installment, seller: create(:user))

        get @action, params: @params.merge(id: other_installment.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The installment was not found."
        }.as_json)
      end

      it "fails gracefully on an unknown id" do
        get @action, params: @params.merge(id: "#{@installment.external_id}++")

        expect(response.parsed_body).to eq({
          success: false,
          message: "The installment was not found."
        }.as_json)
      end
    end
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @params = {
        subject: "Launch update",
        body: "<p>Hello, world!</p>",
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create_access_token("edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "creates a draft installment with email sending enabled by default" do
        post @action, params: @params

        installment = @user.installments.alive.sole
        expect(installment.name).to eq("Launch update")
        expect(installment.message).to eq("<p>Hello, world!</p>")
        expect(installment.installment_type).to eq(Installment::AUDIENCE_TYPE)
        expect(installment.send_emails?).to be(true)
        expect(installment.published?).to be(false)
        expect(response.parsed_body["installment"]).to include(
          "id" => installment.external_id,
          "subject" => "Launch update",
          "state" => "draft",
          "send_emails" => true
        )
      end

      it "publishes and enqueues the blast when requested" do
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

        expect do
          post @action, params: @params.merge(publish: "true")
        end.to change(PostEmailBlast, :count).by(1)

        installment = @user.installments.alive.sole
        expect(installment.published?).to be(true)
        expect(response.parsed_body["installment"]["state"]).to eq("published")
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "publishes when draft is false" do
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

        post @action, params: @params.merge(draft: "false")

        expect(@user.installments.alive.sole).to be_published
      end

      {
        "all" => Installment::AUDIENCE_TYPE,
        "audience" => Installment::AUDIENCE_TYPE,
        "customers" => Installment::SELLER_TYPE,
        "seller" => Installment::SELLER_TYPE,
        "followers" => Installment::FOLLOWER_TYPE,
        "follower" => Installment::FOLLOWER_TYPE,
      }.each do |audience, installment_type|
        it "maps audience #{audience} to #{installment_type}" do
          post @action, params: @params.merge(audience:)

          expect(@user.installments.alive.sole.installment_type).to eq(installment_type)
        end
      end

      it "returns a helpful error for an invalid audience" do
        post @action, params: @params.merge(audience: "invalid_audience")

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq(
          "Invalid audience. Valid values are: all, audience, customers, seller, followers, follower, product."
        )
        expect(@user.installments.alive.count).to eq(0)
      end

      it "requires a product id for product audience emails" do
        post @action, params: @params.merge(audience: "product")

        expect(response.parsed_body).to eq({
          success: false,
          message: "Product audience requires a product_id or link_id."
        }.as_json)
        expect(@user.installments.alive.count).to eq(0)
      end

      it "threads product_id to the installment" do
        product = create(:product, user: @user)

        post @action, params: @params.merge(audience: "product", product_id: product.external_id)

        installment = @user.installments.alive.sole
        expect(installment.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment.link).to eq(product)
        expect(response.parsed_body["installment"]["product_id"]).to eq(product.external_id)
      end

      it "threads link_id to the installment" do
        product = create(:product, user: @user)

        post @action, params: @params.merge(audience: "product", link_id: product.unique_permalink)

        installment = @user.installments.alive.sole
        expect(installment.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment.link).to eq(product)
      end
    end
  end

  describe "POST 'preview'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :preview
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create_access_token("edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "sends a preview email and returns the preview URL" do
        expect_any_instance_of(Installment).to receive(:send_preview_email).with(@user)

        post @action, params: @params

        expect(response.parsed_body).to include(
          "success" => true,
          "preview_url" => edit_email_path(@installment.external_id, preview_post: true),
          "message" => "A preview has been sent to your email."
        )
        expect(response.parsed_body["installment"]["id"]).to eq(@installment.external_id)
      end

      it "returns preview email errors" do
        allow_any_instance_of(Installment)
          .to receive(:send_preview_email)
          .and_raise(Installment::PreviewEmailError, "Preview failed.")

        post @action, params: @params

        expect(response.parsed_body).to eq({
          success: false,
          message: "Preview failed."
        }.as_json)
      end
    end
  end

  describe "POST 'send_email'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :send_email
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create_access_token("edit_products")
        @params.merge!(access_token: @token.token)
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      end

      it "publishes an existing draft and enqueues the blast" do
        expect do
          post @action, params: @params
        end.to change(PostEmailBlast, :count).by(1)

        expect(@installment.reload.published?).to be(true)
        expect(response.parsed_body["installment"]["state"]).to eq("published")
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "returns an error for an already-published installment" do
        @installment.update!(published_at: Time.current)

        post @action, params: @params

        expect(response.parsed_body).to eq({
          success: false,
          message: "The installment has already been sent."
        }.as_json)
      end
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :destroy
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_products scope"

    describe "when logged in with edit_products scope" do
      before do
        @token = create_access_token("edit_products")
        @params.merge!(access_token: @token.token)
      end

      it "soft-deletes the installment" do
        delete @action, params: @params

        expect(@installment.reload.deleted_at).to be_present
      end

      it "returns the deleted response" do
        delete @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          message: "The installment was deleted successfully."
        }.as_json)
      end
    end
  end
end
