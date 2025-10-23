# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::InstallmentsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  before do
    create(:payment_completed, user: seller)
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
  end

  describe "GET index" do
    let!(:published_installment) { create(:installment, seller:, published_at: 1.day.ago) }
    let(:scheduled_installment) { create(:installment, seller:, ready_to_publish: true) }
    let!(:scheduled_installment_rule) { create(:installment_rule, installment: scheduled_installment, delayed_delivery_time: 1.day) }
    let!(:draft_installment) { create(:installment, seller:) }

    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Installment }
    end

    it "returns seller's paginated published installments" do
      get :index, params: { page: 1, type: "published" }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body[:pagination]).to eq({ count: 1, next: nil }.as_json)
      expect(response.parsed_body[:installments]).to eq([InstallmentPresenter.new(seller:, installment: published_installment).props.as_json])
    end

    it "returns seller's paginated scheduled installments" do
      get :index, params: { page: 1, type: "scheduled" }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body[:pagination]).to eq({ count: 1, next: nil }.as_json)
      expect(response.parsed_body[:installments]).to eq([InstallmentPresenter.new(seller:, installment: scheduled_installment).props.as_json])
    end

    it "returns seller's paginated draft installments" do
      get :index, params: { page: 1, type: "draft" }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body[:pagination]).to eq({ count: 1, next: nil }.as_json)
      expect(response.parsed_body[:installments]).to eq([InstallmentPresenter.new(seller:, installment: draft_installment).props.as_json])
    end

    it "returns seller's paginated installments for the specified query" do
      another_installment = create(:installment, seller:, name: "Don't miss!", published_at: 1.day.ago)

      index_model_records(Installment)

      get :index, params: { page: 1, type: "published", query: "miss" }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body[:pagination]).to eq({ count: 1, next: nil }.as_json)
      expect(response.parsed_body[:installments]).to eq([InstallmentPresenter.new(seller:, installment: another_installment).props.as_json])
    end

    it "raises an error for invalid type" do
      expect do
        get :index, params: { page: 1, type: "invalid" }, format: :json
      end.to raise_error(ArgumentError, "Invalid type")
    end
  end

  describe "GET new" do
    it_behaves_like "authentication required for action", :get, :new

    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Installment }
    end

    it "returns necessary props" do
      get :new, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to eq(InstallmentPresenter.new(seller:).new_page_props.as_json)
    end

    it "returns necessary props when copying from an installment" do
      reference_installment = create(:product_installment, seller:)
      get :new, params: { copy_from: reference_installment.external_id }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body).to eq(InstallmentPresenter.new(seller:).new_page_props(copy_from: reference_installment.external_id).as_json)
    end
  end

  describe "POST create" do
    let(:product) { create(:product, user: seller) }
    let(:params) do
      {
        installment: {
          affiliate_products: nil,
          allow_comments: true,
          bought_from: "United States",
          bought_products: [product.unique_permalink],
          bought_variants: [],
          created_after: "2024-01-01",
          created_before: "2024-01-31",
          files: [{ external_id: SecureRandom.uuid, stream_only: false, subtitles: [], url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt" }],
          installment_type: "product",
          link_id: product.unique_permalink,
          message: "<p>Hello, world!</p>",
          name: "Hello",
          not_bought_products: [],
          not_bought_variants: [],
          paid_less_than_cents: 2000,
          paid_more_than_cents: 1000,
          send_emails: true,
          shown_on_profile: true,
        },
        publish: false,
        send_preview_email: false,
        to_be_published_at: nil,
        variant_external_id: nil,
      }
    end

    it_behaves_like "authentication required for action", :post, :create

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Installment }
      let(:request_params) { params }
    end

    it "creates a product-type installment" do
      expect do
        post :create, params:, as: :json
      end.to change { Installment.count }.by(1)

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.seller).to eq(seller)
      expect(installment.name).to eq("Hello")
      expect(installment.product_type?).to be(true)
      expect(installment.link).to eq(product)
      expect(installment.bought_from).to eq("United States")
      expect(installment.bought_products).to eq([product.unique_permalink])
      expect(installment.bought_variants).to be_nil
      expect(installment.created_after.to_date).to eq(Date.parse("2024-01-01"))
      expect(installment.created_before.to_date).to eq(Date.parse("2024-01-31"))
      expect(installment.paid_less_than_cents).to eq(2000)
      expect(installment.paid_more_than_cents).to eq(1000)
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.published?).to be(false)
      expect(installment.product_files.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
      expect(response.parsed_body["installment_id"]).to eq(installment.external_id)
      expect(response.parsed_body["full_url"]).to eq(installment.full_url)
    end

    it "creates a variant-type installment" do
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      post :create, params: params.deep_merge(installment: { installment_type: "variant", bought_variants: [variant.external_id], bought_products: [] }, variant_external_id: variant.external_id), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.variant_type?).to be(true)
      expect(installment.bought_variants).to eq([variant.external_id])
      expect(installment.bought_products).to be_nil
      expect(installment.link).to eq(product)
      expect(installment.base_variant).to eq(variant)
    end

    it "creates a seller-type installment" do
      product2 = create(:product, user: seller)
      post :create, params: params.deep_merge(installment: { installment_type: "seller", link_id: nil, bought_products: [product.unique_permalink, product2.unique_permalink] }), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.seller_type?).to be(true)
      expect(installment.bought_products).to eq([product.unique_permalink, product2.unique_permalink])
    end

    it "creates an audience-type installment" do
      post :create, params: params.deep_merge(installment: { installment_type: "audience", link_id: nil, bought_products: nil, not_bought_products: [product.unique_permalink] }), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.audience_type?).to be(true)
      expect(installment.bought_products).to be_nil
      expect(installment.not_bought_products).to eq([product.unique_permalink])
    end

    it "creates a follower-type installment" do
      post :create, params: params.deep_merge(installment: { installment_type: "follower", link_id: nil }), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.follower_type?).to be(true)
      expect(installment.bought_products).to eq([product.unique_permalink])
    end

    it "creates an affiliate-type installment" do
      post :create, params: params.deep_merge(installment: { installment_type: "affiliate", link_id: nil, affiliate_products: [product.unique_permalink], bought_products: nil }), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.affiliate_type?).to be(true)
      expect(installment.bought_products).to be_nil
      expect(installment.affiliate_products).to eq([product.unique_permalink])
    end

    it "creates and publishes the installment" do
      post :create, params: params.merge(publish: true), as: :json

      expect(response).to be_successful
      expect(Installment.last.published?).to be(true)
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
    end

    it "returns an error while publishing an installment if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)
      post :create, params: params.merge(publish: true), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You are not eligible to publish or schedule emails. Please ensure you have made at least $100 in sales and received a payout.")
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "publishes the installment but does not send emails" do
      post :create, params: params.deep_merge(publish: true, installment: { send_emails: false }), as: :json

      expect(response).to be_successful
      expect(Installment.last.published?).to be(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "creates and sends a preview email" do
      allow(PostSendgridApi).to receive(:process).and_call_original

      post :create, params: params.merge(send_preview_email: true), as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.published?).to be(false)
      expect(PostSendgridApi).to have_received(:process).with(
        post: installment,
        recipients: [{
          email: seller.seller_memberships.role_admin.sole.user.email,
          url_redirect: installment.url_redirects.sole,
        }],
        preview: true,
      )
    end

    it "sends a preview email to the impersonated Gumroad admin" do
      gumroad_admin = create(:admin_user)
      sign_in(gumroad_admin)
      controller.impersonate_user(seller)
      expect_any_instance_of(Installment).to receive(:send_preview_email).with(gumroad_admin)

      post :create, params: params.merge(send_preview_email: true), as: :json
    end

    it "returns an error while previewing an email if the logged-in user has uncofirmed email" do
      controller.logged_in_user.update_attribute(:unconfirmed_email, "john@example.com")
      expect(PostSendgridApi).to_not receive(:process)

      expect do
        post :create, params: params.merge(send_preview_email: true), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You have to confirm your email address before you can do that.")
    end

    it "creates and schedules the installment" do
      freeze_time do
        expect do
          post :create, params: params.merge(to_be_published_at: 1.day.from_now), as: :json
        end.to change { InstallmentRule.count }.by(1)

        expect(response).to be_successful
        installment = Installment.last
        expect(installment.published?).to be(false)
        expect(installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(installment.id, 1).at(1.day.from_now)
      end
    end

    it "returns an error while scheduling an installment if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      expect do
        post :create, params: params.merge(to_be_published_at: 1.day.from_now), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You are not eligible to publish or schedule emails. Please ensure you have made at least $100 in sales and received a payout.")
      expect(PublishScheduledPostJob.jobs).to be_empty
    end

    it "returns an error if the schedule date is in past" do
      expect do
        post :create, params: params.merge(to_be_published_at: 1.day.ago), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please select a date and time in the future.")
    end

    it "returns an error if no channel is provided" do
      expect do
        post :create, params: params.deep_merge(installment: { send_emails: nil, shown_on_profile: nil }), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please set at least one channel for your update.")
    end

    it "returns an error if paid more than is greater than paid less than" do
      expect do
        post :create, params: params.deep_merge(installment: { paid_more_than_cents: 5000 }), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please enter valid paid more than and paid less than values.")
    end

    it "returns an error if bought after date is after bought before date" do
      expect do
        post :create, params: params.deep_merge(installment: { created_after: "2024-01-31", created_before: "2024-01-01" }), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please enter valid before and after dates.")
    end

    it "returns an error if the message is missing" do
      expect do
        post :create, params: params.deep_merge(installment: { message: nil }), as: :json
      end.to_not change { Installment.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please include a message as part of the update.")
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let(:params) do
      {
        installment: {
          affiliate_products: nil,
          allow_comments: true,
          bought_from: "United States",
          bought_products: [product.unique_permalink],
          bought_variants: [],
          created_after: "2024-01-01",
          created_before: "2024-01-31",
          files: [{ external_id: SecureRandom.uuid, stream_only: false, subtitles: [], url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt" }],
          installment_type: "product",
          link_id: product.unique_permalink,
          message: "<p>Hello, world!</p>",
          name: "Hello",
          not_bought_products: [],
          not_bought_variants: [],
          paid_less_than_cents: 2000,
          paid_more_than_cents: 1000,
          send_emails: true,
          shown_on_profile: true,
        },
        publish: false,
        send_preview_email: false,
        to_be_published_at: nil,
        variant_external_id: nil,
      }
    end
    let(:installment) { create(:installment, seller:, installment_type: "seller") }

    it_behaves_like "authentication required for action", :put, :update do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id }.merge(params) }
    end

    it "updates the installment" do
      expect do
        put :update, params: params.merge(id: installment.external_id), as: :json
      end.to change { installment.reload.installment_type }.to("product")

      expect(response).to be_successful
      expect(installment.name).to eq("Hello")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.link).to eq(product)
      expect(installment.seller).to eq(seller)
      expect(installment.bought_products).to eq([product.unique_permalink])
      expect(installment.bought_variants).to be_nil
      expect(installment.bought_from).to eq("United States")
      expect(installment.paid_less_than_cents).to eq(2000)
      expect(installment.paid_more_than_cents).to eq(1000)
      expect(installment.created_after.to_date).to eq(Date.parse("2024-01-01"))
      expect(installment.created_before.to_date).to eq(Date.parse("2024-01-31"))
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.published?).to be(false)
      expect(installment.product_files.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
      expect(response.parsed_body["installment_id"]).to eq(installment.external_id)
      expect(response.parsed_body["full_url"]).to eq(installment.full_url)
    end

    it "marks the old file as deleted" do
      installment.product_files.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/old-url.txt")
      expect do
        put :update, params: params.merge(id: installment.external_id), as: :json
      end.to change { installment.reload.product_files.count }.from(1).to(2)
      expect(installment.product_files.alive.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
    end

    it "removes the existing files" do
      installment.product_files.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/old-url.txt")
      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { files: [] }), as: :json
      end.to change { installment.reload.product_files.alive.count }.from(1).to(0)

      expect(response).to be_successful
    end

    it "updates and publishes the installment" do
      expect do
        put :update, params: params.merge(id: installment.external_id, publish: true), as: :json
      end.to change { installment.reload.published? }.from(false).to(true)

      expect(response).to be_successful
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      expect(response.parsed_body["installment_id"]).to eq(installment.external_id)
      expect(response.parsed_body["full_url"]).to eq(installment.full_url)
      expect(installment.name).to eq("Hello")
    end

    it "updates and publishes the installment but does not send emails" do
      put :update, params: params.deep_merge(id: installment.external_id, publish: true, installment: { send_emails: false }), as: :json

      expect(response).to be_successful
      expect(installment.reload.published?).to be(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
      expect(installment.name).to eq("Hello")
    end

    it "allows updating only certain attributes for a published installment" do
      freeze_time do
        installment.update!(published_at: 10.days.ago, shown_on_profile: false, send_emails: true, allow_comments: false)

        expect do
          put :update, params: params.deep_merge(id: installment.external_id, installment: { published_at: 2.days.ago.to_date, send_emails: false }), as: :json
        end.to change { installment.reload.published_at }.from(10.days.ago).to(2.days.ago.to_date)
          .and change { installment.name }.to("Hello")
          .and change { installment.message }.to("<p>Hello, world!</p>")
          .and change { installment.shown_on_profile }.from(false).to(true)
          .and change { installment.send_emails }.from(true).to(false)
          .and change { installment.allow_comments }.from(false).to(true)
          .and not_change { installment.installment_type }
          .and not_change { installment.bought_products }
          .and not_change { installment.bought_variants }
          .and not_change { installment.bought_from }
          .and not_change { installment.paid_less_than_cents }
          .and not_change { installment.paid_more_than_cents }
          .and not_change { installment.created_after }
          .and not_change { installment.created_before }

        expect(response).to be_successful
      end
    end

    it "does not allow updating 'send_emails' if it has been published and already blasted" do
      create(:blast, post: installment)
      installment.update!(published_at: 10.days.ago, send_emails: true)

      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { send_emails: false }), as: :json
      end.to_not change { installment.reload.send_emails }

      expect(response).to be_successful
    end

    it "updates the installment but do not change the publish date if it is unchanged for a published installment" do
      installment.update!(published_at: 10.days.ago)

      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { published_at: 10.days.ago.to_date }), as: :json
      end.to_not change { installment.reload.published_at }

      expect(response).to be_successful
      expect(installment.reload.published?).to be(true)
      expect(installment.name).to eq("Hello")
    end

    it "does not allow a future publish date for an already published installment" do
      installment.update!(published_at: 1.day.ago)

      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { published_at: 1.day.from_now.to_date }), as: :json
      end.to_not change { installment.reload.published_at }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please enter a publish date in the past.")
      expect(installment.name).to_not eq("Hello")
    end

    it "updates the installment and sends a preview email" do
      allow(PostSendgridApi).to receive(:process).and_call_original

      put :update, params: params.merge(id: installment.external_id, send_preview_email: true), as: :json

      expect(response).to be_successful
      expect(installment.reload.published?).to be(false)
      expect(installment.name).to eq("Hello")
      expect(PostSendgridApi).to have_received(:process).with(
        post: installment,
        recipients: [{
          email: seller.seller_memberships.role_admin.sole.user.email,
          url_redirect: installment.url_redirects.sole,
        }],
        preview: true,
      )
    end

    it "updates the installment and sends a preview email to the impersonated Gumroad admin" do
      gumroad_admin = create(:admin_user)
      sign_in(gumroad_admin)
      controller.impersonate_user(seller)
      expect_any_instance_of(Installment).to receive(:send_preview_email).with(gumroad_admin)

      put :update, params: params.merge(id: installment.external_id, send_preview_email: true), as: :json

      expect(response).to be_successful
      expect(installment.reload.published?).to eq(false)
      expect(installment.name).to eq("Hello")
    end

    it "returns an error while previewing an email if the logged-in user has uncofirmed email" do
      controller.logged_in_user.update_attribute(:unconfirmed_email, "john@example.com")
      expect(PostSendgridApi).to_not receive(:process)

      expect do
        put :update, params: params.merge(id: installment.external_id, send_preview_email: true), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You have to confirm your email address before you can do that.")
    end

    it "updates the installment and schedules the installment" do
      freeze_time do
        expect do
          put :update, params: params.merge(id: installment.external_id, to_be_published_at: 1.day.from_now), as: :json
        end.to change { InstallmentRule.count }.by(1)

        expect(response).to be_successful
        expect(installment.reload.published?).to be(false)
        expect(installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(installment.id, 1).at(1.day.from_now)
      end
    end

    it "updates the installment and changes the existing schedule time of an already scheduled installment" do
      freeze_time do
        installment_rule = create(:installment_rule, installment:, to_be_published_at: 1.day.from_now)

        expect do
          put :update, params: params.merge(id: installment.external_id, to_be_published_at: 15.day.from_now), as: :json
        end.to change { installment_rule.reload.to_be_published_at }.from(1.day.from_now).to(15.days.from_now)

        expect(response).to be_successful
        expect(installment.reload.name).to eq("Hello")
        expect(installment.published?).to be(false)
        expect(installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(installment.id, 2).at(15.days.from_now)
      end
    end

    it "returns an error if the schedule date is in past" do
      expect do
        put :update, params: params.merge(id: installment.external_id, to_be_published_at: 1.day.ago), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please select a date and time in the future.")
    end

    it "returns an error while scheduling if the seller has not confirmed their email address" do
      seller.update!(confirmed_at: nil)

      expect do
        put :update, params: params.merge(id: installment.external_id, to_be_published_at: 1.day.from_now), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "You have to confirm your email address before you can do that.")
    end

    it "returns an error if paid more than is greater than paid less than" do
      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { paid_more_than_cents: 5000 }), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please enter valid paid more than and paid less than values.")
    end

    it "returns an error if bought after date is after bought before date" do
      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { created_after: "2024-01-31", created_before: "2024-01-01" }), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please enter valid before and after dates.")
    end

    it "returns an error if the message is missing" do
      expect do
        put :update, params: params.deep_merge(id: installment.external_id, installment: { message: nil }), as: :json
      end.to_not change { installment.reload }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("message" => "Please include a message as part of the update.")
    end
  end

  describe "DELETE destroy" do
    let(:installment) { create(:installment, seller:) }
    let(:installment_rule) { create(:installment_rule, installment:) }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { installment }
      let(:request_params) { { id: installment.external_id } }
    end

    it "marks the installment as deleted" do
      expect do
        delete :destroy, params: { id: installment.external_id }, format: :json
      end.to change { installment.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))
         .and change { installment_rule.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
    end

    it "returns an error if the installment cannot be deleted" do
      installment.published_at = DateTime.current + 1.day
      installment.save(validate: false)

      expect do
        expect do
          delete :destroy, params: { id: installment.external_id }, format: :json
        end.to_not change { installment.reload.deleted_at }
      end.to_not change { installment_rule.reload.deleted_at }

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => false, "message" => "Sorry, something went wrong. Please try again.")
    end
  end
end
