# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::SalesController, :vcr do
  include CdnUrlHelper

  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @purchaser = create(:user)
    @app = create(:oauth_application, owner: @seller)
    @params = {
      mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN,
      access_token: create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "mobile_api").token
    }
    @purchase = create(:purchase_in_progress, link: @product, seller: @seller, price_cents: 100, total_transaction_cents: 100,
                                              fee_cents: 30, chargeable: create(:chargeable))
    @purchase.process!
    @purchase.mark_successful!
  end

  describe "GET show" do
    it "returns purchase information" do
      get :show, params: @params.merge(id: @purchase.external_id)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["purchase"].to_json).to eq(@purchase.json_data_for_mobile(include_sale_details: true).to_json)
    end

    it "returns customer details, charges, and emails" do
      get :show, params: @params.merge(id: @purchase.external_id)

      expect(response).to be_successful
      body = response.parsed_body
      seller_context = SellerContext.new(user: @seller, seller: @seller)
      expect(body["customer"].to_json).to eq(CustomerPresenter.new(purchase: @purchase).customer(pundit_user: seller_context).to_json)
      expect(body["charges"]).to eq([])
      expect(body["emails"].length).to eq(1)
      expect(body["emails"].first).to include("type" => "receipt", "id" => @purchase.external_id)
    end
  end

  describe "GET index" do
    before do
      travel_to(Time.utc(2024, 1, 1)) do
        @older_purchase = create(:purchase, link: @product, seller: @seller, email: "alice@example.com", full_name: "Alice Apple", price_cents: 300)
      end
      travel_to(Time.utc(2024, 2, 1)) do
        @newer_purchase = create(:purchase, link: @product, seller: @seller, email: "bob@example.com", full_name: "Bob Banana", price_cents: 200)
      end
      index_model_records(Purchase)
    end

    it "returns sales sorted by most recent" do
      get :index, params: @params

      expect(response).to be_successful
      body = response.parsed_body
      expect(body["success"]).to eq(true)
      expect(body["purchases"].map { _1["id"] }).to eq([@purchase.external_id, @newer_purchase.external_id, @older_purchase.external_id])
      expect(body["purchases"].second).to include(
        "email" => "bob@example.com",
        "product_name" => @product.name,
      )
      expect(body["pagination"]).to eq("count" => 3, "page" => 1, "pages" => 1, "next" => nil)
    end

    it "filters sales with the query parameter" do
      get :index, params: @params.merge(query: "alice@example.com")

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@older_purchase.external_id])
      expect(body["pagination"]["count"]).to eq(1)
    end

    it "paginates sales" do
      stub_const("Api::Mobile::SalesController::SALES_PER_PAGE", 2)

      get :index, params: @params

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@purchase.external_id, @newer_purchase.external_id])
      expect(body["pagination"]).to eq("count" => 3, "page" => 1, "pages" => 2, "next" => 2)

      get :index, params: @params.merge(page: 2)

      body = response.parsed_body
      expect(body["purchases"].map { _1["id"] }).to eq([@older_purchase.external_id])
      expect(body["pagination"]).to eq("count" => 3, "page" => 2, "pages" => 2, "next" => nil)
    end

    it "returns 504 when Elasticsearch times out" do
      allow(PurchaseSearchService).to receive(:search).and_raise(Faraday::TimeoutError)

      get :index, params: @params

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.parsed_body).to eq("success" => false, "message" => "Sales request timed out")
    end
  end

  describe "PUT update" do
    it "updates the purchase email" do
      put :update, params: @params.merge(id: @purchase.external_id, email: "new@example.com")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.email).to eq("new@example.com")
    end

    it "rolls back gift updates when the main purchase save fails" do
      gift = create(:gift, gifter_purchase: @purchase)
      giftee_purchase = create(:purchase, link: @product, seller: @seller, is_gift_receiver_purchase: true)
      gift.update!(giftee_purchase:)
      @purchase.update!(gift_given: gift, is_gift_sender_purchase: true)

      allow_any_instance_of(Purchase).to receive(:save!).and_wrap_original do |method, *args|
        raise ActiveRecord::RecordInvalid, method.receiver if method.receiver.id == @purchase.id
        method.call(*args)
      end

      expect do
        put :update, params: @params.merge(id: @purchase.external_id, email: "new@example.com", giftee_email: "giftee@example.com")
      end.to not_change { gift.reload.giftee_email }
         .and not_change { giftee_purchase.reload.email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
    end

    it "returns a controlled error without writing when a gift sale has no giftee purchase" do
      gift = create(:gift, gifter_purchase: @purchase, giftee_purchase: nil)
      @purchase.update!(gift_given: gift, is_gift_sender_purchase: true)

      expect do
        put :update, params: @params.merge(id: @purchase.external_id, email: "new@example.com", giftee_email: "giftee@example.com")
      end.to not_change { @purchase.reload.email }
         .and not_change { gift.reload.giftee_email }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("success" => false, "message" => "This gift is missing a giftee purchase")
    end
  end

  describe "POST change_can_contact" do
    it "updates can_contact" do
      post :change_can_contact, params: @params.merge(id: @purchase.external_id, can_contact: "false")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.can_contact).to eq(false)
    end
  end

  describe "POST mark_as_shipped" do
    it "marks the purchase as shipped" do
      post :mark_as_shipped, params: @params.merge(id: @purchase.external_id, tracking_url: "https://example.com/track")

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.shipment.shipped?).to eq(true)
      expect(@purchase.shipment.tracking_url).to eq("https://example.com/track")
    end

    it "returns a controlled error and does not mark shipped when the shipment fails to persist" do
      shipment = Shipment.new(purchase: @purchase)
      shipment.errors.add(:base, "Something went wrong")
      allow(shipment).to receive(:persisted?).and_return(false)
      allow(Shipment).to receive(:create).and_return(shipment)

      post :mark_as_shipped, params: @params.merge(id: @purchase.external_id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("Something went wrong")
      expect(@purchase.reload.shipment).to be_nil
    end
  end

  describe "PUT revoke_access and undo_revoke_access" do
    it "toggles access revocation" do
      put :revoke_access, params: @params.merge(id: @purchase.external_id)
      expect(@purchase.reload.is_access_revoked).to eq(true)

      put :undo_revoke_access, params: @params.merge(id: @purchase.external_id)
      expect(@purchase.reload.is_access_revoked).to eq(false)
    end

    it "rejects revoke_access for an already-revoked purchase" do
      @purchase.update!(is_access_revoked: true)

      put :revoke_access, params: @params.merge(id: @purchase.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "Not authorized")
    end

    it "rejects revoke_access for a refunded purchase" do
      allow_any_instance_of(Purchase).to receive(:refunded?).and_return(true)

      put :revoke_access, params: @params.merge(id: @purchase.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "Not authorized")
      expect(@purchase.reload.is_access_revoked).to eq(false)
    end

    it "rejects revoke_access for a physical purchase" do
      physical_product = create(:physical_product, user: @seller)
      physical_purchase = create(:physical_purchase, link: physical_product, seller: @seller)

      put :revoke_access, params: @params.merge(id: physical_purchase.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "Not authorized")
      expect(physical_purchase.reload.is_access_revoked).to eq(false)
    end

    it "rejects revoke_access for a subscription purchase" do
      membership_product = create(:membership_product, user: @seller)
      subscription = create(:subscription, link: membership_product, seller: @seller)
      subscription_purchase = create(:purchase, link: membership_product, seller: @seller, subscription:, is_original_subscription_purchase: true)

      put :revoke_access, params: @params.merge(id: subscription_purchase.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "Not authorized")
      expect(subscription_purchase.reload.is_access_revoked).to eq(false)
    end

    it "rejects undo_revoke_access for a purchase whose access is not revoked" do
      put :undo_revoke_access, params: @params.merge(id: @purchase.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "Not authorized")
    end
  end

  describe "cross-seller authorization" do
    before do
      @other_seller = create(:user)
      @other_product = create(:product, user: @other_seller)
      @other_purchase = create(:purchase, link: @other_product, seller: @other_seller, can_contact: true)
      create(:product_review, purchase: @other_purchase, link: @other_product, rating: 5)
    end

    it "returns 404 for another seller's sale on show" do
      get :show, params: @params.merge(id: @other_purchase.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
    end

    it "returns 404 for another seller's sale on update" do
      put :update, params: @params.merge(id: @other_purchase.external_id, email: "new@example.com")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
      expect(@other_purchase.reload.email).not_to eq("new@example.com")
    end

    it "returns 404 for another seller's sale on refund" do
      patch :refund, params: @params.merge(id: @other_purchase.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "error" => "Not found")
    end

    it "returns 404 for another seller's sale on revoke_access" do
      put :revoke_access, params: @params.merge(id: @other_purchase.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
      expect(@other_purchase.reload.is_access_revoked).to eq(false)
    end

    it "returns 404 for another seller's sale on resend_receipt" do
      post :resend_receipt, params: @params.merge(id: @other_purchase.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
    end

    it "returns 404 for another seller's sale on send_post" do
      post :send_post, params: @params.merge(id: @other_purchase.external_id, post_id: "anything")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
    end

    it "returns 404 for another seller's sale on update_review_response" do
      put :update_review_response, params: @params.merge(id: @other_purchase.external_id, message: "Thanks!")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find purchase")
    end
  end

  describe "PUT review_response" do
    before do
      create(:product_review, purchase: @purchase, link: @product, rating: 5)
    end

    it "creates and deletes a review response" do
      put :update_review_response, params: @params.merge(id: @purchase.external_id, message: "Thank you!")

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.original_product_review.response.message).to eq("Thank you!")

      delete :destroy_review_response, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(@purchase.reload.original_product_review.response).to be_nil
    end
  end

  describe "GET options" do
    it "returns the product's variant options" do
      get :options, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["options"]).to eq(@product.options.as_json)
    end

    context "when the purchase's product has been deleted" do
      before do
        @purchase.update_column(:link_id, nil)
      end

      it "responds with a controlled error instead of crashing" do
        expect do
          get :options, params: @params.merge(id: @purchase.external_id)
        end.not_to raise_error

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Could not find product")
      end
    end
  end

  describe "PUT variant" do
    context "when the purchase's product has been deleted" do
      before do
        @purchase.update_column(:link_id, nil)
      end

      it "responds with a controlled error instead of crashing" do
        expect do
          put :variant, params: @params.merge(id: @purchase.external_id, variant_id: "anything")
        end.not_to raise_error

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Could not find product")
      end
    end

    context "with an unknown variant_id" do
      it "responds with a controlled 404 instead of crashing" do
        expect do
          put :variant, params: @params.merge(id: @purchase.external_id, variant_id: "nonexistent")
        end.not_to raise_error

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Variant not found")
      end
    end
  end

  describe "GET missed_posts" do
    it "returns missed posts for the purchase" do
      get :missed_posts, params: @params.merge(id: @purchase.external_id)

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["missed_posts"]).to eq([])
    end
  end

  describe "PATCH refund" do
    context "when the purchase is not found" do
      it "responds with HTTP 404" do
        patch :refund, params: @params.merge(id: "notfound")

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the purchase is not paid" do
      it "responds with HTTP 404" do
        purchase = create(:free_purchase)
        patch :refund, params: @params.merge(id: purchase.external_id)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the purchase is already refunded" do
      it "responds with HTTP 404" do
        @purchase.update!(stripe_refunded: true)
        patch :refund, params: @params.merge(id: @purchase.external_id)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
      end
    end

    context "when the amount contains a comma" do
      it "responds with invalid request error" do
        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "1,00")

        expect(response.parsed_body).to eq "success" => false, "message" => "Commas not supported in refund amount."
      end
    end

    context "when the purchase is refunded" do
      it "responds with HTTP success" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(10_00)
        @seller.update_attribute(:refund_fee_notice_shown, false)
        expect do
          patch :refund, params: @params.merge(id: @purchase.external_id)

          expect(response).to be_successful
          expect(response.parsed_body).to eq "success" => true, "id" => @purchase.external_id, "message" => "Purchase successfully refunded.", "partially_refunded" => false
        end.to change { @purchase.reload.refunded? }.from(false).to(true)
         .and change { @purchase.seller.refund_fee_notice_shown? }.from(false).to(true)
      end
    end

    context "when there's a refunding error" do
      before do
        allow_any_instance_of(Purchase).to receive(:refund!).and_return(false)
        allow_any_instance_of(Purchase).to receive_message_chain(:errors, :full_messages, :to_sentence).and_return("Refund error")
      end

      it "response with error message" do
        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "100")

        expect(response.parsed_body).to eq "success" => false, "message" => "Refund error"
      end
    end

    context "when there's a record invalid exception" do
      before do
        allow_any_instance_of(Purchase).to receive(:refund!).and_raise(ActiveRecord::RecordInvalid)
      end

      it "notifies error tracker and responds with error message" do
        expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid))

        patch :refund, params: @params.merge(id: @purchase.external_id, amount: "100")

        expect(response.parsed_body).to eq "success" => false, "message" => "Sorry, something went wrong."
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "POST resend_receipt" do
    it "resends the receipt" do
      expect_any_instance_of(Purchase).to receive(:resend_receipt)

      post :resend_receipt, params: @params.merge(id: @purchase.external_id)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
    end

    it "responds with a controlled 404 when the chargeable order has no buyer email" do
      allow_any_instance_of(Api::Mobile::SalesController).to receive(:receipt_orderable_missing?).and_return(true)
      expect_any_instance_of(Purchase).not_to receive(:resend_receipt)

      post :resend_receipt, params: @params.merge(id: @purchase.external_id)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find receipt")
    end
  end

  describe "POST send_post" do
    before do
      @post = create(:installment, link: @product, seller: @seller, published_at: Time.current)
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(true)
    end

    it "sends the post and reports it as sent" do
      expect(PostEmailApi).to receive(:process)

      post :send_post, params: @params.merge(id: @purchase.external_id, post_id: @post.external_id)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "sent" => true)
    end

    it "does not resend within the 8-hour rate limit window and reports it as not sent" do
      Rails.cache.write("post_email:#{@post.id}:#{@purchase.id}", true)
      expect(PostEmailApi).not_to receive(:process)

      post :send_post, params: @params.merge(id: @purchase.external_id, post_id: @post.external_id)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "sent" => false)
    end

    it "rejects sellers who are not eligible to send emails" do
      allow_any_instance_of(User).to receive(:eligible_to_send_emails?).and_return(false)
      expect(PostEmailApi).not_to receive(:process)

      post :send_post, params: @params.merge(id: @purchase.external_id, post_id: @post.external_id)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("success" => false, "message" => "You are not eligible to resend this email.")
    end
  end

  describe "GET blob_url" do
    let(:build_blob) do
      ->(filename) { ActiveStorage::Blob.create_before_direct_upload!(filename:, byte_size: 100, checksum: "abc", content_type: "application/octet-stream", metadata: { analyzed: true, identified: true }) }
    end

    before do
      @seller.update!(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day)
    end

    it "returns the cdn url for a blob attached to the seller's commission" do
      commission_product = create(:commission_product, user: @seller)
      deposit_purchase = create(:purchase, seller: @seller, link: commission_product, price_cents: 100, displayed_price_cents: 100)
      commission = create(:commission, deposit_purchase:)
      blob = build_blob.call("test.pdf")
      commission.files.attach(blob)

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "url" => cdn_url_for(blob.url))
    end

    it "returns the cdn url for a blob attached to the seller's commission completion purchase" do
      commission_product = create(:commission_product, user: @seller)
      deposit_purchase = create(:purchase, seller: @seller, link: commission_product, price_cents: 100, displayed_price_cents: 100)
      completion_purchase = create(:purchase, seller: @seller, link: commission_product, price_cents: 100, displayed_price_cents: 100)
      commission = create(:commission, deposit_purchase:, completion_purchase:)
      blob = build_blob.call("test.pdf")
      commission.files.attach(blob)

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "url" => cdn_url_for(blob.url))
    end

    it "returns the cdn url for a blob attached to a file custom field on the seller's sale" do
      custom_field = create(:purchase_custom_field, field_type: CustomField::TYPE_FILE, purchase: @purchase, name: CustomField::FILE_FIELD_NAME, value: nil)
      blob = build_blob.call("smilie.png")
      custom_field.files.attach(blob)

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true, "url" => cdn_url_for(blob.url))
    end

    it "returns 404 for a blob belonging to another seller's commission" do
      other_seller = create(:user, :eligible_for_service_products)
      other_purchase = create(:purchase, seller: other_seller, link: create(:commission_product, user: other_seller), price_cents: 100, displayed_price_cents: 100)
      other_commission = create(:commission, deposit_purchase: other_purchase)
      blob = build_blob.call("test.pdf")
      other_commission.files.attach(blob)

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find file")
    end

    it "returns 404 for a blob attached to another seller's file custom field" do
      other_seller = create(:user)
      other_product = create(:product, user: other_seller)
      other_purchase = create(:purchase, seller: other_seller, link: other_product)
      custom_field = create(:purchase_custom_field, field_type: CustomField::TYPE_FILE, purchase: other_purchase, name: CustomField::FILE_FIELD_NAME, value: nil)
      blob = build_blob.call("smilie.png")
      custom_field.files.attach(blob)

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find file")
    end

    it "returns 404 for a blob that is not attached to any owned record" do
      blob = build_blob.call("smilie.png")

      get :blob_url, params: @params.merge(key: blob.key)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find file")
    end

    it "returns 404 for an unknown key" do
      get :blob_url, params: @params.merge(key: "does-not-exist")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "message" => "Could not find file")
    end
  end
end
