# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::EmailsController do
  before do
    @user = create(:user, email: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_access_token(scopes)
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes:)
  end

  def create_product_owned_installment(**attributes)
    create(:product_installment, { link: create(:product, user: @user), seller: nil }.merge(attributes))
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
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
        expect(response.parsed_body["emails"].map { _1["id"] })
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
        expect(response.parsed_body["emails"].map { _1["id"] }).to eq([published.external_id])

        get @action, params: @params.merge(type: Installment::SCHEDULED)
        expect(response.parsed_body["emails"].map { _1["id"] }).to eq([scheduled.external_id])

        get @action, params: @params.merge(type: Installment::DRAFT)
        expect(response.parsed_body["emails"].map { _1["id"] }).to eq([draft.external_id])
      end

      it "paginates installments with a page key" do
        per_page = Api::V2::EmailsController::RESULTS_PER_PAGE
        installments = (0..per_page).map do |index|
          create(:audience_installment, seller: @user, created_at: (per_page - index).minutes.ago)
        end
        expected_installments = installments.sort_by { |installment| [installment.created_at, installment.id] }.reverse

        get @action, params: @params

        expect(response.parsed_body["emails"].map { _1["id"] })
          .to eq(expected_installments.first(per_page).map(&:external_id))
        expect(response.parsed_body["next_page_key"]).to be_present
        expect(response.parsed_body["next_page_url"]).to include("/v2/emails")

        get @action, params: @params.merge(page_key: response.parsed_body["next_page_key"])

        expect(response.parsed_body).to eq({
          success: true,
          emails: expected_installments[per_page..].as_json(api_scopes: ["edit_emails"])
        }.as_json)
      end

      it "does not drop installments whose ids are not ordered by creation time" do
        per_page = Api::V2::EmailsController::RESULTS_PER_PAGE
        installments = (0..per_page).map do |index|
          create(:audience_installment, seller: @user, created_at: index.minutes.ago)
        end
        expected_order = installments.sort_by { |installment| [installment.created_at, installment.id] }.reverse

        get @action, params: @params
        first_page_ids = response.parsed_body["emails"].map { _1["id"] }
        expect(first_page_ids).to eq(expected_order.first(per_page).map(&:external_id))

        next_page_key = response.parsed_body["next_page_key"]
        expect(next_page_key).to be_present

        get @action, params: @params.merge(page_key: next_page_key)
        second_page_ids = response.parsed_body["emails"].map { _1["id"] }
        expect(second_page_ids).to eq(expected_order[per_page..].map(&:external_id))

        expect(first_page_ids + second_page_ids).to match_array(installments.map(&:external_id))
      end

      it "returns an empty list for another seller's installments" do
        create(:audience_installment, seller: create(:user))

        get @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          emails: []
        }.as_json)
      end

      it "returns installments owned through the seller's products" do
        product_owned_installment = create_product_owned_installment
        other_seller_product_owned_installment = create(
          :product_installment,
          link: create(:product, user: create(:user)),
          seller: nil
        )

        get @action, params: @params

        email_ids = response.parsed_body["emails"].map { _1["id"] }
        expect(email_ids).to include(product_owned_installment.external_id)
        expect(email_ids).not_to include(other_seller_product_owned_installment.external_id)
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
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
        @params.merge!(access_token: @token.token)
      end

      it "returns the installment" do
        get @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          email: @installment.as_json(api_scopes: ["edit_emails"])
        }.as_json)
      end

      it "returns an installment owned through one of the seller's products" do
        product_owned_installment = create_product_owned_installment

        get @action, params: @params.merge(id: product_owned_installment.external_id)

        expect(response.parsed_body["email"]["id"]).to eq(product_owned_installment.external_id)
      end

      it "does not return another seller's installment" do
        other_installment = create(:audience_installment, seller: create(:user))

        get @action, params: @params.merge(id: other_installment.external_id)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The email was not found."
        }.as_json)
      end

      it "fails gracefully on an unknown id" do
        get @action, params: @params.merge(id: "#{@installment.external_id}++")

        expect(response.parsed_body).to eq({
          success: false,
          message: "The email was not found."
        }.as_json)
      end

      it "returns an absolute URL for a published installment" do
        @installment.update!(published_at: Time.current)
        allow_any_instance_of(User).to receive(:subdomain_with_protocol).and_return(nil)

        get @action, params: @params

        expect(response.parsed_body["email"]["url"]).to eq(view_post_url(
          host: UrlService.domain_with_protocol,
          username: @installment.user.username,
          slug: @installment.slug
        ))
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
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
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
        expect(response.parsed_body["email"]).to include(
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
        expect(response.parsed_body["email"]["state"]).to eq("published")
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "publishes when draft is false" do
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

        expect do
          post @action, params: @params.merge(draft: "false")
        end.to change(PostEmailBlast, :count).by(1)

        expect(@user.installments.alive.sole.published?).to be(true)
        expect(response.parsed_body["email"]["state"]).to eq("published")
      end

      it "does not publish from a blank draft parameter" do
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

        expect do
          post @action, params: @params.merge(draft: "")
        end.not_to change(PostEmailBlast, :count)

        expect(@user.installments.alive.sole.published?).to be(false)
        expect(response.parsed_body["email"]["state"]).to eq("draft")
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

      it "targets a product audience to that product's buyers" do
        product = create(:product, user: @user)

        post @action, params: @params.merge(audience: "product", product_id: product.external_id)

        installment = @user.installments.alive.sole
        expect(installment.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment.link).to eq(product)
        expect(installment.bought_products).to eq([product.unique_permalink])
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
        expect(response.parsed_body["email"]["product_id"]).to eq(product.external_id)
      end

      it "threads link_id to the installment" do
        product = create(:product, user: @user)

        post @action, params: @params.merge(audience: "product", link_id: product.unique_permalink)

        installment = @user.installments.alive.sole
        expect(installment.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment.link).to eq(product)
      end
    end

    it "grants create access with the account scope used by the CLI" do
      token = create_access_token("account")

      post @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body["success"]).to be(true)
      expect(@user.installments.alive.sole).not_to be_published
    end
  end

  describe "POST 'preview'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :preview
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
        @params.merge!(access_token: @token.token)
      end

      it "sends a preview email and returns an absolute preview URL" do
        expect_any_instance_of(Installment).to receive(:send_preview_email).with(@user)

        post @action, params: @params

        expect(response.parsed_body).to include(
          "success" => true,
          "preview_url" => edit_email_url(@installment.external_id, preview_post: true, host: UrlService.domain_with_protocol),
          "message" => "A preview has been sent to your email."
        )
        expect(response.parsed_body["preview_url"]).to start_with("http")
        expect(response.parsed_body["email"]["id"]).to eq(@installment.external_id)
      end

      it "sends a preview for an email owned through one of the seller's products" do
        product_owned_installment = create_product_owned_installment
        expect(PostEmailApi).to receive(:process) do |post:, recipients:, preview:|
          expect(post).to eq(product_owned_installment)
          expect(post.seller).to eq(@user)
          expect(recipients).to eq([{ email: @user.email }])
          expect(preview).to be(true)
        end

        post @action, params: @params.merge(id: product_owned_installment.external_id)

        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["email"]["id"]).to eq(product_owned_installment.external_id)
        expect(response.parsed_body["preview_url"]).to eq(edit_email_url(product_owned_installment.external_id, preview_post: true, host: UrlService.domain_with_protocol))
        expect(product_owned_installment.reload.seller).to eq(@user)
        expect(@user.installments.alive.find_by_external_id(product_owned_installment.external_id)).to eq(product_owned_installment)
      end

      it "returns an absolute preview URL for a published email" do
        @installment.update!(published_at: Time.current)
        allow_any_instance_of(User).to receive(:subdomain_with_protocol).and_return(nil)
        expect_any_instance_of(Installment).to receive(:send_preview_email).with(@user)

        post @action, params: @params

        expect(response.parsed_body["preview_url"]).to eq(view_post_url(
          host: UrlService.domain_with_protocol,
          username: @installment.user.username,
          slug: @installment.slug
        ))
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

      it "returns a JSON error and notifies for unexpected preview failures" do
        error = StandardError.new("Provider unavailable.")
        allow_any_instance_of(Installment)
          .to receive(:send_preview_email)
          .and_raise(error)
        expect(ErrorNotifier).to receive(:notify).with(error)

        post @action, params: @params

        expect(response.parsed_body).to eq({
          success: false,
          message: "Provider unavailable."
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
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
        @params.merge!(access_token: @token.token)
        allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      end

      it "publishes an existing draft and enqueues the blast" do
        expect do
          post @action, params: @params
        end.to change(PostEmailBlast, :count).by(1)

        expect(@installment.reload.published?).to be(true)
        expect(response.parsed_body["email"]["state"]).to eq("published")
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends an email owned through one of the seller's products" do
        product_owned_installment = create_product_owned_installment

        expect do
          post @action, params: @params.merge(id: product_owned_installment.external_id)
        end.to change(PostEmailBlast, :count).by(1)

        expect(product_owned_installment.reload).to be_published
        expect(product_owned_installment.seller).to eq(@user)
        expect(product_owned_installment.bought_products).to eq([product_owned_installment.link.unique_permalink])
        expect(response.parsed_body["email"]["id"]).to eq(product_owned_installment.external_id)
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends a variant-owned email to buyers of the variant" do
        product = create(:product, user: @user)
        variant = create(:variant, variant_category: create(:variant_category, link: product))
        variant_owned_installment = create(
          :variant_installment,
          link: product,
          seller: nil,
          base_variant: variant,
          bought_products: [],
          bought_variants: []
        )

        expect do
          post @action, params: @params.merge(id: variant_owned_installment.external_id)
        end.to change(PostEmailBlast, :count).by(1)

        expect(variant_owned_installment.reload).to be_published
        expect(variant_owned_installment.seller).to eq(@user)
        expect(variant_owned_installment.bought_products).to be_nil
        expect(variant_owned_installment.bought_variants).to eq([variant.external_id])
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends a published product-owned profile-only post that has not been blasted" do
        product_owned_installment = create_product_owned_installment(published_at: 1.hour.ago)
        product_owned_installment.assign_attributes(send_emails: false, shown_on_profile: true)
        product_owned_installment.save!(validate: false)

        expect do
          post @action, params: @params.merge(id: product_owned_installment.external_id)
        end.to change(PostEmailBlast, :count).by(1)

        expect(product_owned_installment.reload.seller).to eq(@user)
        expect(PostEmailBlast.last.seller).to eq(@user)
        expect(product_owned_installment.bought_products).to eq([product_owned_installment.link.unique_permalink])
        expect(response.parsed_body["email"]).to include(
          "id" => product_owned_installment.external_id,
          "send_emails" => true,
          "shown_on_profile" => true,
          "state" => "published"
        )
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends a published variant-owned profile-only post to buyers of the variant" do
        product = create(:product, user: @user)
        variant = create(:variant, variant_category: create(:variant_category, link: product))
        variant_owned_installment = create(:variant_installment, link: product, seller: nil, base_variant: variant, published_at: 1.hour.ago)
        variant_owned_installment.assign_attributes(send_emails: false, shown_on_profile: true, bought_products: [], bought_variants: [])
        variant_owned_installment.save!(validate: false)

        expect do
          post @action, params: @params.merge(id: variant_owned_installment.external_id)
        end.to change(PostEmailBlast, :count).by(1)

        expect(variant_owned_installment.reload.seller).to eq(@user)
        expect(variant_owned_installment.bought_products).to be_nil
        expect(variant_owned_installment.bought_variants).to eq([variant.external_id])
        expect(PostEmailBlast.last.seller).to eq(@user)
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "turns a profile-only draft into an email blast" do
        @installment.update!(send_emails: false, shown_on_profile: true)

        expect do
          post @action, params: @params
        end.to change(PostEmailBlast, :count).by(1)

        expect(@installment.reload.send_emails?).to be(true)
        expect(@installment.published?).to be(true)
        expect(response.parsed_body["email"]).to include(
          "send_emails" => true,
          "shown_on_profile" => true,
          "state" => "published"
        )
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends a published profile-only post that has not been blasted" do
        @installment.update!(published_at: 1.hour.ago, send_emails: false, shown_on_profile: true)

        expect do
          post @action, params: @params
        end.to change(PostEmailBlast, :count).by(1)

        expect(@installment.reload.send_emails?).to be(true)
        expect(@installment.published?).to be(true)
        expect(response.parsed_body["email"]).to include(
          "send_emails" => true,
          "shown_on_profile" => true,
          "state" => "published"
        )
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "sends a published scheduled profile-only post that has not been blasted" do
        scheduled = create(
          :scheduled_installment,
          seller: @user,
          link: nil,
          installment_type: Installment::AUDIENCE_TYPE,
          published_at: 1.hour.ago
        )
        scheduled.assign_attributes(send_emails: false, shown_on_profile: true)
        scheduled.save!(validate: false)
        scheduled.installment_rule.mark_deleted!

        expect do
          post @action, params: @params.merge(id: scheduled.external_id)
        end.to change(PostEmailBlast, :count).by(1)

        expect(scheduled.reload.send_emails?).to be(true)
        expect(scheduled.published?).to be(true)
        expect(response.parsed_body["email"]).to include(
          "send_emails" => true,
          "shown_on_profile" => true,
          "state" => "published"
        )
        expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      end

      it "keeps attached files when publishing a draft" do
        file = create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/magic.mp3")
        @installment.product_files << file

        post @action, params: @params

        expect(response.parsed_body["success"]).to be(true)
        expect(@installment.reload.alive_product_files.map(&:external_id)).to include(file.external_id)
      end

      it "returns an error for an already-blasted email" do
        @installment.update!(published_at: Time.current)
        create(:blast, post: @installment)

        post @action, params: @params

        expect(response.parsed_body).to eq({
          success: false,
          message: "The email has already been sent."
        }.as_json)
      end

      it "does not immediately send a scheduled email" do
        scheduled = create(
          :scheduled_installment,
          seller: @user,
          link: nil,
          installment_type: Installment::AUDIENCE_TYPE
        )

        expect do
          post @action, params: @params.merge(id: scheduled.external_id)
        end.not_to change(PostEmailBlast, :count)

        expect(response.parsed_body).to eq({
          success: false,
          message: "The email is scheduled to be sent at its scheduled time."
        }.as_json)
        expect(scheduled.reload.published?).to be(false)
      end
    end

    it "grants send access with the account scope used by the CLI" do
      token = create_access_token("account")
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)

      expect do
        post @action, params: @params.merge(access_token: token.token)
      end.to change(PostEmailBlast, :count).by(1)

      expect(@installment.reload).to be_published
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
    end
  end

  describe "DELETE 'destroy'" do
    before do
      @installment = create(:audience_installment, seller: @user)
      @action = :destroy
      @params = { id: @installment.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    describe "when logged in with edit_emails scope" do
      before do
        @token = create_access_token("edit_emails")
        @params.merge!(access_token: @token.token)
      end

      it "soft-deletes the installment" do
        delete @action, params: @params

        expect(@installment.reload.deleted_at).to be_present
      end

      it "soft-deletes an email owned through one of the seller's products" do
        product_owned_installment = create_product_owned_installment

        delete @action, params: @params.merge(id: product_owned_installment.external_id)

        expect(product_owned_installment.reload.deleted_at).to be_present
      end

      it "returns the deleted response" do
        delete @action, params: @params

        expect(response.parsed_body).to eq({
          success: true,
          message: "The email was deleted successfully."
        }.as_json)
      end
    end
  end
end
