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
    if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).blank?
      create(:merchant_account, user: nil)
    end
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

      expect(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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

    it "does not send again when sent cache writes fail after provider delivery is recorded" do
      sent_cache_write_attempts = 0
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        after_provider_delivery&.call
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end
      allow(Rails.cache).to receive(:write).and_wrap_original do |original_method, key, value, *args, **kwargs|
        if key.to_s.start_with?("single_customer_email_delivery:") && value == described_class::DELIVERY_SENT_CACHE_VALUE
          sent_cache_write_attempts += 1
          raise "cache unavailable after provider send" if sent_cache_write_attempts <= 2
        end

        original_method.call(key, value, *args, **kwargs)
      end

      expect do
        post :create, params: request_params, as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)
        .and change(CreatorContactingCustomersEmailInfo, :count).by(1)

      expect(response).to be_successful
      first_installment = Installment.last
      delivery_cache_key = "single_customer_email_delivery:#{first_installment.id}:#{purchase.id}"
      expect(Rails.cache.read(delivery_cache_key)).to eq(described_class::DELIVERY_IN_PROGRESS_CACHE_VALUE)
      expect(PostEmailApi).to have_received(:process).once

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)
        .and not_change(CreatorContactingCustomersEmailInfo, :count)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(Installment.last).to eq(first_installment)
      expect(PostEmailApi).to have_received(:process).once
      expect(Rails.cache.read(delivery_cache_key)).to eq(described_class::DELIVERY_SENT_CACHE_VALUE)
    end

    it "does not send again when provider delivery is accepted before a post-send failure" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        after_provider_delivery&.call
        raise "post-provider side effect failed"
      end

      expect do
        expect { post :create, params: request_params, as: :json }.to raise_error("post-provider side effect failed")
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)
        .and change(CreatorContactingCustomersEmailInfo, :count).by(1)

      first_installment = Installment.last
      delivery_cache_key = "single_customer_email_delivery:#{first_installment.id}:#{purchase.id}"
      expect(Rails.cache.read(delivery_cache_key)).to eq(described_class::DELIVERY_SENT_CACHE_VALUE)
      email_info = CreatorContactingCustomersEmailInfo.where(purchase:, installment: first_installment).sole
      expect(email_info.state).to eq("sent")
      expect(email_info.sent_at).to be_present
      expect(PostEmailApi).to have_received(:process).once

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)
        .and not_change(CreatorContactingCustomersEmailInfo, :count)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(PostEmailApi).to have_received(:process).once
    end

    it "uses Redis locks for both installment creation and delivery idempotency" do
      lock_keys = []
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end
      allow($redis).to receive(:set).and_wrap_original do |original_method, *args, **kwargs|
        lock_keys << args.first if args.first.to_s.end_with?(":lock")
        original_method.call(*args, **kwargs)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      expect(lock_keys).to include(
        a_string_starting_with("single_customer_email:#{seller.id}:#{purchase.id}:")
      )
      expect(lock_keys).to include("single_customer_email_delivery:#{Installment.last.id}:#{purchase.id}:lock")
    end

    it "reserves delivery with a short in-progress TTL before the provider call without holding the Redis lock while sending" do
      delivery_cache_values = []
      delivery_lock_values = []
      delivery_cache_writes = []

      allow(Rails.cache).to receive(:write).and_wrap_original do |original_method, *args, **kwargs|
        key, value, options = args
        options = (options || {}).merge(kwargs)
        delivery_cache_writes << { key:, value:, expires_in: options[:expires_in] } if key.to_s.start_with?("single_customer_email_delivery:")

        original_method.call(*args, **kwargs)
      end

      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        delivery_cache_key = "single_customer_email_delivery:#{post.id}:#{purchase.id}"
        delivery_cache_values << Rails.cache.read(delivery_cache_key)
        delivery_lock_values << $redis.get("#{delivery_cache_key}:lock")
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      delivery_cache_key = "single_customer_email_delivery:#{Installment.last.id}:#{purchase.id}"
      expect(delivery_cache_values).to eq([described_class::DELIVERY_IN_PROGRESS_CACHE_VALUE])
      expect(delivery_lock_values).to eq([nil])
      expect(delivery_cache_writes).to include(
        { key: delivery_cache_key, value: described_class::DELIVERY_IN_PROGRESS_CACHE_VALUE, expires_in: described_class::DELIVERY_IN_PROGRESS_CACHE_TTL },
        { key: delivery_cache_key, value: described_class::DELIVERY_SENT_CACHE_VALUE, expires_in: described_class::DELIVERY_CACHE_TTL }
      )
      expect(Rails.cache.read(delivery_cache_key)).to eq(described_class::DELIVERY_SENT_CACHE_VALUE)
      expect(Rails.cache.read("post_email:#{Installment.last.id}:#{purchase.id}")).to be_nil
      expect(PostEmailApi).to have_received(:process).once
    end

    it "does not send again while delivery for the cached installment is already in progress" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      post :create, params: request_params, as: :json

      expect(response).to be_successful
      installment = Installment.last
      delivery_cache_key = "single_customer_email_delivery:#{installment.id}:#{purchase.id}"
      CreatorContactingCustomersEmailInfo.where(purchase:, installment:).destroy_all
      Rails.cache.write(
        delivery_cache_key,
        described_class::DELIVERY_IN_PROGRESS_CACHE_VALUE,
        expires_in: described_class::DELIVERY_IN_PROGRESS_CACHE_TTL
      )

      expect do
        post :create, params: request_params, as: :json
      end.to not_change(Installment, :count)
        .and not_change(PostEmailBlast, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("success" => false, "message" => "This email is already being sent. Please wait a few minutes before trying again.")
      expect(PostEmailApi).to have_received(:process).once
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

    it "accepts image-only messages that survive installment message scrubbing" do
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      image_only_message = '<p><img src="https://example.com/image.png"></p>'

      expect do
        post :create, params: request_params.merge(message: image_only_message), as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(Installment.last.message).to include("<img")
    end

    it "resolves inline upsell cards so the published message can render" do
      upsell_product = create(:product, user: seller)
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
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

    it "returns a JSON 422 for a gift sender sale even via a direct POST" do
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

    it "allows emailing a gift receiver sale" do
      gift_sender_purchase = create(:free_purchase, :gift_sender, seller:, link: product, email: "gifter@example.com", can_contact: true)
      gift_receiver_purchase = create(:free_purchase, :gift_receiver, seller:, link: product, email: "giftee@example.com", can_contact: true)
      create(
        :gift,
        gifter_purchase: gift_sender_purchase,
        giftee_purchase: gift_receiver_purchase,
        gifter_email: gift_sender_purchase.email,
        giftee_email: gift_receiver_purchase.email,
        link: product
      )
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        expect(recipients).to eq([{ email: gift_receiver_purchase.email, purchase: gift_receiver_purchase }])
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase: gift_receiver_purchase)
      end

      expect do
        post :create, params: request_params.merge(purchase_id: gift_receiver_purchase.external_id), as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
      expect(PostEmailApi).to have_received(:process).once
    end

    it "does not apply the blast audience limit to a single-recipient email" do
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)
      allow_any_instance_of(Installment).to receive(:audience_members_count).and_return(Installment::SENDING_LIMIT + 1)
      allow(PostEmailApi).to receive(:process) do |post:, recipients:, after_provider_delivery: nil|
        create(:creator_contacting_customers_email_info_sent, installment: post, purchase:)
      end

      expect do
        post :create, params: request_params, as: :json
      end.to change(Installment, :count).by(1)
        .and change(PostEmailBlast, :count).by(1)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
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
