# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe Api::Internal::Customers::SingleCustomerEmailsController do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, seller:, link: product, email: "buyer@example.com", can_contact: true) }
  let(:request_params) do
    {
      purchase_id: purchase.external_id,
      name: "A quick update",
      message: "<p>Thanks for your purchase.</p>",
    }
  end

  include_context "with user signed in as admin for seller"

  before do
    Rails.cache.clear
    create(:payment_completed, user: seller)
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
  end

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Installment }
      let(:policy_method) { :create? }
      let(:request_format) { :json }
    end

    it "creates a published non-blastable seller email and sends it only to the purchase email" do
      purchase.create_url_redirect!

      expect(PostEmailApi).to receive(:process) do |post:, recipients:|
        expect(recipients).to eq(
          [
            {
              email: purchase.email,
              purchase:,
              url_redirect: purchase.url_redirect,
            }
          ]
        )
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      expect do
        post :create, params: request_params, as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to eq("success" => true)

      installment = Installment.last
      expect(installment.seller).to eq(seller)
      expect(installment.installment_type).to eq(Installment::SELLER_TYPE)
      expect(installment.name).to eq("A quick update")
      expect(installment.message).to eq("<p>Thanks for your purchase.</p>")
      expect(installment).to be_published
      expect(installment).to be_send_emails
      expect(installment.has_been_blasted?).to eq(true)
      expect(installment.can_be_blasted?).to eq(false)
      expect(installment.blasts.sole.completed_at).to be_present

      email_info = CreatorContactingCustomersEmailInfo.where(purchase:, installment:).sole
      expect(email_info.state).to eq("sent")
      expect(purchase.installments.alive.published.seller_type).to include(installment)
    end

    it "deduplicates identical retries and sends different content separately" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        expect(recipients).to eq(
          [
            {
              email: purchase.email,
              purchase:,
            }
          ]
        )
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      expect do
        post :create, params: request_params, as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(PostEmailApi).to have_received(:process).once
      first_installment = Installment.last

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(PostEmailApi).to have_received(:process).once
      expect(Installment.last).to eq(first_installment)

      different_request_params = request_params.merge(
        name: "Another quick update",
        message: "<p>Thanks again for your purchase.</p>"
      )

      expect do
        post :create, params: different_request_params, as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(PostEmailApi).to have_received(:process).twice
      expect(Installment.last).to_not eq(first_installment)
    end

    it "does not create a second installment when delivery fails, and re-delivers on retry" do
      attempts = 0
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        attempts += 1
        raise "provider unavailable" if attempts == 1

        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      expect do
        expect { post :create, params: request_params, as: :json }.to raise_error("provider unavailable")
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)
      first_installment = Installment.last

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(Installment.last).to eq(first_installment)
      expect(PostEmailApi).to have_received(:process).twice
    end

    it "returns a JSON 422 when the message is empty after scrubbing" do
      expect(PostEmailApi).to_not receive(:process)

      expect do
        post :create, params: request_params.merge(message: "<p><br></p>"), as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("application/json")
      expect(response).to_not be_redirect
      expect(response.parsed_body).to eq("success" => false, "message" => "Please include a message as part of the update.")
    end

    it "resolves inline upsell cards so the published message can render" do
      upsell_product = create(:product, user: seller)
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      message = %(<p>Check this out.</p><upsell-card productid="#{upsell_product.external_id}"></upsell-card>)

      expect do
        post :create, params: request_params.merge(message:), as: :json
      end.to change(Installment, :count).by(1)
        .and change(Upsell, :count).by(1)

      expect(response).to be_successful
      installment = Installment.last
      upsell_id = Nokogiri::HTML.fragment(installment.message).at_css("upsell-card")["id"]
      expect(upsell_id).to be_present
      expect(seller.upsells.find_by_external_id!(upsell_id)).to eq(Upsell.last)
    end

    it "keeps the one-off email out of seller-post targeting for other customers" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.single_recipient_email?).to eq(true)

      other_purchase = create(:purchase, seller:, link: product, email: "another@example.com", can_contact: true)
      expect(Installment.emailable_posts_for_purchase(purchase: other_purchase)).to_not include(installment)
      expect(Installment.missed_for_purchase(other_purchase)).to_not include(installment)
    end

    it "is viewable only by the recipient, not by other customers of the seller" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      installment = Installment.last
      other_purchase = create(:purchase, seller:, link: product, email: "another@example.com", can_contact: true)

      expect(installment.eligible_purchase?(purchase)).to eq(true)
      expect(installment.eligible_purchase?(other_purchase)).to eq(false)
    end

    it "delivers attachments through an installment-scoped download link" do
      received_url_redirect = nil
      allow(PostEmailApi).to receive(:process) do |post:, recipients:|
        received_url_redirect = recipients.first[:url_redirect]
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      params = request_params.merge(
        files: [{ external_id: SecureRandom.uuid, url: "#{S3_BASE_URL}attachments/12345/abcd12345/original/manual.pdf" }]
      )

      post :create, params: params, as: :json

      expect(response).to be_successful
      installment = Installment.last
      expect(installment.has_files?).to eq(true)
      expect(received_url_redirect).to be_present
      expect(received_url_redirect.installment_id).to eq(installment.id)
      expect(received_url_redirect.purchase_id).to eq(purchase.id)
    end

    it "returns a JSON 404 when the purchase does not belong to the seller" do
      other_purchase = create(:purchase, email: "other@example.com")
      expect(PostEmailApi).to_not receive(:process)

      post :create, params: request_params.merge(purchase_id: other_purchase.external_id), as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq("application/json")
      expect(response).to_not be_redirect
      expect(response.parsed_body).to eq("success" => false, "message" => "Customer not found.")
    end

    it "returns a JSON 422 when the purchase cannot be contacted" do
      create(:purchase, seller:, link: product, email: "contactable@example.com", can_contact: true)
      purchase.update!(can_contact: false)
      expect(PostEmailApi).to_not receive(:process)

      post :create, params: request_params, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("application/json")
      expect(response).to_not be_redirect
      expect(response.parsed_body).to eq("success" => false, "message" => "Customer cannot be emailed.")
    end

    it "returns a JSON 422 when the purchase email is invalid" do
      purchase.update_column(:email, "invalid")
      expect(PostEmailApi).to_not receive(:process)

      post :create, params: request_params, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("application/json")
      expect(response).to_not be_redirect
      expect(response.parsed_body).to eq("success" => false, "message" => "Customer cannot be emailed.")
    end

    it "returns a JSON 422 for a gift sale even via a direct POST" do
      # Keep the seller's customers-audience non-empty via a separate normal sale,
      # so the request reaches the gift guard rather than the audience check.
      create(:purchase, seller:, link: product, email: "normal@example.com", can_contact: true)
      create(:gift, gifter_purchase: purchase, giftee_email: "giftee@example.com", link: product)
      purchase.update!(is_gift_sender_purchase: true)
      expect(PostEmailApi).to_not receive(:process)

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count).and not_change(PostEmailBlast, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("application/json")
      expect(response.parsed_body).to eq("success" => false, "message" => "Customer cannot be emailed.")
    end

    it "delivers the email after the installment and blast are committed" do
      purchase.create_url_redirect!

      expect(PostEmailApi).to receive(:process) do
        # The installment + blast must already be persisted (committed) before
        # the external send runs, so a send is never made for a record that a
        # later rollback would erase.
        installment = Installment.last
        expect(installment).to be_persisted
        expect(installment).to be_published
        expect(installment.blasts.count).to eq(1)
        create(:creator_contacting_customers_email_info_sent, installment:, purchase:)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
    end

    it "returns a JSON 404 when the seller does not have a customers email audience" do
      purchase
      seller.audience_members.destroy_all
      expect(PostEmailApi).to_not receive(:process)

      post :create, params: request_params, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq("application/json")
      expect(response).to_not be_redirect
      expect(response.parsed_body).to eq("success" => false, "message" => "Customer not found.")
    end
  end
end
