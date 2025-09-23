# frozen_string_literal: false

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/order_association_with_cart_post_checkout"

include CurrencyHelper

describe PurchasesController, :vcr do
  include ManageSubscriptionHelpers

  render_views

  let(:price) { 600 }
  let(:product) { create(:product, price_cents: price) }
  let(:zero_plus_link) { create(:product, price_range: "0+") }
  let(:two_plus_link) { create(:product, price_range: "2+") }
  let(:params) do
    { permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      cc_zipcode_required: "false",
      cc_zipcode: "12345",
      quantity: 1 }.merge(StripePaymentMethodHelper.success.to_stripejs_params)
  end

  let(:stripejs_params) do
    { permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      quantity: 1 }.merge(StripePaymentMethodHelper.success.to_stripejs_params)
  end

  let(:stripejs_params_declined) do
    { permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      quantity: 1 }.merge(StripePaymentMethodHelper.decline.to_stripejs_params)
  end

  let(:stripejs_card_error_params) do
    { card_data_handling_mode: "stripejs.0",
      stripe_error: {
        type: "card_error",
        code: "cvc_check_failed",
        message: "G'day mate. Your CVC aint right."
      },
      permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      quantity: 1 }
  end

  let(:stripejs_other_error_params) do
    { card_data_handling_mode: "stripejs.0",
      stripe_error: {
        type: "api_error",
        message: "That's a knife?"
      },
      permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      quantity: 1 }
  end

  let(:invalid_zipcode_params) do
    { permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      cc_zipcode_required: "true",
      cc_zipcode: "12345",
      quantity: 1 }.merge(StripePaymentMethodHelper.success_zip_check_fails.with_zip_code.to_stripejs_params)
  end

  let(:invalid_zipcode_params_no_zip_code) do
    { permalink: product.unique_permalink,
      email: "sahil@gumroad.com",
      perceived_price_cents: price,
      cc_zipcode_required: "true",
      quantity: 1 }.merge(StripePaymentMethodHelper.success_zip_check_fails.to_stripejs_params)
  end

  let(:zero_plus_params) do
    { permalink: zero_plus_product.unique_permalink,
      email: "mike2@gumroad.com",
      perceived_price_cents: 0,
      price_range: "0",
      cc_zipcode_required: "false",
      cc_zipcode: "12345",
      quantity: 1 }
  end

  let(:two_plus_params) do
    { permalink: two_plus_product.unique_permalink,
      email: "mike3@gumroad.com",
      perceived_price_cents: 200,
      price_range: "200",
      cc_zipcode_required: "false",
      cc_zipcode: "12345",
      quantity: 1 }.merge(StripePaymentMethodHelper.success.to_stripejs_params)
  end

  let(:sca_params) do
    { permalink: product.unique_permalink,
      email: Faker::Internet.email,
      perceived_price_cents: price,
      quantity: 1 }.merge(StripePaymentMethodHelper.success_with_sca.to_stripejs_params)
  end

  # Created a second link that is different from the first one and lets us simulate 2 different purchases.
  let(:other_link) { create(:product, price_cents: price) }
  let(:other_params) do
    { permalink: other_product.unique_permalink,
      email: "mike@gumroad.com",
      perceived_price_cents: price,
      cc_zipcode_required: "false",
      cc_zipcode: "12345",
      quantity: 1 }.merge(StripePaymentMethodHelper.success.to_stripejs_params)
  end
  let(:seller) { create(:named_seller) }

  before do
    cookies[:_gumroad_guid] = SecureRandom.uuid
  end

  context "within seller area" do
    include_context "with user signed in as admin for seller"

    describe "PUT update" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product, seller:, email: "k@gumroad.com") }
      let(:obfuscated_id) { ObfuscateIds.encrypt(purchase.id) }

      it_behaves_like "authorize called for action", :put, :update do
        let(:record) { purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: obfuscated_id, email: " test@gumroad.com" } }
      end

      it "allows to update email address" do
        put :update, params: { id: obfuscated_id, email: " test@gumroad.com" }
        expect(response.parsed_body["success"]).to be(true)
        expect(purchase.reload.email).to eq "test@gumroad.com"
      end

      it "updates email addresses of bundle product purchases" do
        bundle_purchase = create(:purchase, link: create(:product, :bundle, user: seller))
        bundle_purchase.create_artifacts_and_send_receipt!
        put :update, params: { id: bundle_purchase.external_id, email: "newemail@gumroad.com" }
        expect(response.parsed_body["success"]).to be(true)
        expect(bundle_purchase.reload.email).to eq("newemail@gumroad.com")
        expect(bundle_purchase.product_purchases.map(&:email)).to all(eq("newemail@gumroad.com"))
      end

      it "allows to update giftee_email address" do
        product = create(:product, user: seller)
        gifter_email = "gifter@foo.com"
        giftee_email = "giftee@foo.com"
        gift = create(:gift, gifter_email:, giftee_email:, link: product)
        gifter_purchase = create(:purchase, link: product,
                                            seller:,
                                            price_cents: product.price_cents,
                                            email: gifter_email,
                                            purchase_state: "successful",
                                            is_gift_sender_purchase: true,
                                            stripe_transaction_id: "ch_zitkxbhds3zqlt",
                                            can_contact: true)

        gift.gifter_purchase = gifter_purchase

        gift.giftee_purchase = create(:purchase, link: product,
                                                 seller:,
                                                 email: giftee_email,
                                                 price_cents: 0,
                                                 is_gift_receiver_purchase: true,
                                                 purchase_state: "gift_receiver_purchase_successful",
                                                 can_contact: true)
        gift.mark_successful
        gift.save!
        put :update, params: { id: ObfuscateIds.encrypt(gifter_purchase.id), giftee_email: "new_giftee@example.com" }

        expect(response.parsed_body["success"]).to be(true)
        expect(gift.reload.giftee_email).to eq "new_giftee@example.com"
        expect(gift.giftee_purchase.email).to eq("new_giftee@example.com")
      end

      it "allows to update shipping information for the seller" do
        put :update, params: { id: obfuscated_id, street_address: "1640 3rd Street", city: "San Francisco", state: "CA", zip_code: "94107", country: "United States" }
        expect(response.parsed_body["success"]).to be(true)
        purchase.reload
        expect(purchase.street_address).to eq "1640 3rd Street"
        expect(purchase.city).to eq "San Francisco"
        expect(purchase.state).to eq "CA"
        expect(purchase.zip_code).to eq "94107"
        expect(purchase.country).to eq "United States"
      end

      it "does not change shipping information for blank params" do
        purchase.update!(street_address: "1640 3rd Street", city: "San Francisco", state: "CA", zip_code: "94107", country: "United States")
        put :update, params: { id: obfuscated_id, full_name: "John Doe", street_address: "", city: "", state: "", zip_code: "", country: "" }
        expect(response.parsed_body["success"]).to be(true)
        purchase.reload
        expect(purchase.full_name).to eq "John Doe"
        expect(purchase.street_address).to eq "1640 3rd Street"
        expect(purchase.city).to eq "San Francisco"
        expect(purchase.state).to eq "CA"
        expect(purchase.zip_code).to eq "94107"
        expect(purchase.country).to eq "United States"
      end

      it "does not allow to update if signed in user is not a seller" do
        sign_in create(:user)
        put :update, params: { id: obfuscated_id, street_address: "1640 3rd Street", city: "San Francisco", state: "CA", zip_code: "94107", country: "United States" }
        expect(response.parsed_body["success"]).to be(false)
      end
    end

    describe "multiseat license" do
      before do
        @product = create(:membership_product, is_multiseat_license: true, user: seller)
      end

      it "derives product's `is_multiseat_license` for new purchases" do
        purchase = create(:purchase, link: @product)
        expect(purchase.is_multiseat_license).to eq(true)

        @product.update(is_multiseat_license: false)
        new_purchase = create(:purchase, link: @product.reload)
        expect(purchase.reload.is_multiseat_license).to eq(true)
        expect(new_purchase.is_multiseat_license).to eq(false)
      end

      it "updates quantity for purchase with multiseat license enabled" do
        purchase = create(:purchase, link: @product)
        expect(purchase.quantity).to eq(1)

        put :update, params: { id: purchase.external_id, quantity: 2 }
        expect(response.parsed_body["success"]).to be(true)
        expect(purchase.reload.quantity).to eq(2)
      end

      it "does not update quantity for purchase with multiseat license disabled" do
        @product.update(is_multiseat_license: false)
        purchase = create(:purchase, link: @product)
        expect(purchase.is_multiseat_license).to eq(false)
        expect(purchase.quantity).to eq(1)

        put :update, params: { id: purchase.external_id, quantity: 2 }
        expect(purchase.reload.quantity).to eq(1)
      end
    end

    describe "refund" do
      let(:seller) { create(:user, unpaid_balance_cents: 200) }

      it_behaves_like "authorize called for action", :put, :refund do
        let(:record) { Purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: @obfuscated_id, format: :json } }
      end

      before do
        @l = create(:product, user: seller)
        @p = create(:purchase_in_progress, link: @l, seller: @l.user, price_cents: 100, total_transaction_cents: 100, fee_cents: 30,
                                           chargeable: create(:chargeable))
        @p.process!
        @p.mark_successful!
        @obfuscated_id = ObfuscateIds.encrypt(@p.id)

        @old_paypal_purchase = create(:purchase_in_progress, link: @l, seller: @l.user, price_cents: 100, total_transaction_cents: 100, fee_cents: 30, created_at: 7.months.ago, card_type: "paypal")
        @old_paypal_purchase.process!
        @old_paypal_purchase.mark_successful!
      end

      it "404s for already refunded purchases" do
        @p.update!(stripe_refunded: true)
        put :refund, params: { id: @obfuscated_id, format: :json }
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for PayPal purchases that are more than 6 months old" do
        put :refund, params: { id: @old_paypal_purchase.external_id, format: :json }
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
        expect(response).to have_http_status(:not_found)
      end

      it "404s for non existent purchases" do
        put :refund, params: { id: 121_212_121, format: :json }
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
        expect(response).to have_http_status(:not_found)
      end

      it "404s for free 0+ purchases" do
        l = create(:product, price_range: "0+", price_cents: 0, user: seller)
        p = create(:purchase, link: l, seller: l.user, price_cents: 0, total_transaction_cents: 0,
                              stripe_fingerprint: nil, stripe_transaction_id: nil)
        put :refund, params: { id: ObfuscateIds.encrypt(p.id), format: :json }
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
        expect(response).to have_http_status(:not_found)
      end

      it "404s for purchases not belong to this user" do
        other_user = create(:user, unpaid_balance_cents: 200)
        oldproduct = @p.link
        @p.link = create(:product, user: other_user)
        @p.seller = @p.link.user
        @p.save!
        put :refund, params: { id: @obfuscated_id, format: :json }
        expect(response.parsed_body).to eq "success" => false, "error" => "Not found"
        expect(response).to have_http_status(:not_found)
        @p.link = oldproduct
        @p.save
      end

      it "sends refund email" do
        expect do
          put :refund, params: { id: @obfuscated_id, format: :json }
        end.to have_enqueued_mail(CustomerMailer, :refund)
      end

      it "returns status message on success" do
        put :refund, params: { id: @obfuscated_id, format: :json }
        expect(response.parsed_body["success"]).to be(true)
        expect(response.parsed_body["message"]).to_not be(nil)
      end

      it "returns error message on failure" do
        allow_any_instance_of(Purchase).to receive(:refund_and_save!).and_return(false)
        put :refund, params: { id: @obfuscated_id, format: :json }
        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to_not be(nil)
      end

      it "displays insufficient funds error if creator's paypal account does not funds to refund the purchase" do
        allow_any_instance_of(User).to receive(:native_paypal_payment_enabled?).and_return(true)

        purchase = create(:purchase, link: @l, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                                     merchant_account: create(:merchant_account_paypal, charge_processor_merchant_id: "EF7UQSZMFR3UU"),
                                     paypal_order_id: "36842509RK4544740", stripe_transaction_id: "8LE286804S000725B")

        put :refund, params: { id: purchase.external_id, format: :json }

        expect(response.parsed_body["success"]).to be(false)
        expect(response.parsed_body["message"]).to eq("Your PayPal account does not have sufficient funds to make this refund.")
      end

      it "displays an error when refund amount contains commas" do
        put :refund, params: { id: @obfuscated_id, amount: "1,00", format: :json }

        expect(response.parsed_body["success"]).to eq(false)
        expect(response.parsed_body["message"]).to eq("Commas not supported in refund amount.")
      end

      it "issues a full refund when total amount is passed as param" do
        put :refund, params: { id: @obfuscated_id, amount: "1.00", format: :json }

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["id"]).to eq(@p.external_id)
        expect(response.parsed_body["partially_refunded"]).to eq(false)
      end

      it "issues a partial refund when partial amount is passed as param" do
        put :refund, params: { id: @obfuscated_id, amount: "0.50", format: :json }

        expect(response.parsed_body["success"]).to eq(true)
        expect(response.parsed_body["id"]).to eq(@p.external_id)
        expect(response.parsed_body["partially_refunded"]).to eq(true)
      end

      context "when product is sold in a single unit currency type" do
        before do
          @l.update!(price_currency_type: "jpy", price_cents: 1000)
          @p1 = create(:purchase_in_progress,
                       link: @l,
                       seller: @l.user,
                       price_cents: 914,
                       total_transaction_cents: 100,
                       fee_cents: 54,
                       displayed_price_cents: 1000,
                       displayed_price_currency_type: "jpy",
                       rate_converted_to_usd: "109.383",
                       chargeable: create(:chargeable))
          @p1.process!
          @p1.mark_successful!

          @obfuscated_id = ObfuscateIds.encrypt(@p1.id)
          allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)
        end

        it "issues a partial refund when partial amount is passed as param" do
          put :refund, params: { id: @obfuscated_id, amount: "500", format: :json }

          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["id"]).to eq(@p1.external_id)
          expect(response.parsed_body["partially_refunded"]).to eq(true)
        end

        it "issues a full refund when amount param is missing" do
          put :refund, params: { id: @obfuscated_id, format: :json }

          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["id"]).to eq(@p1.external_id)
          expect(response.parsed_body["partially_refunded"]).to eq(false)
        end

        it "issues a full refund when total amount is passed as param" do
          put :refund, params: { id: @obfuscated_id, amount: "1000", format: :json }

          expect(response.parsed_body["success"]).to eq(true)
          expect(response.parsed_body["id"]).to eq(@p1.external_id)
          expect(response.parsed_body["partially_refunded"]).to eq(false)
        end
      end

      context "when there's a record invalid exception" do
        before do
          allow_any_instance_of(Purchase).to receive(:refund!).and_raise(ActiveRecord::RecordInvalid)
        end

        it "notifies Bugsnag and responds with error message" do
          expect(Bugsnag).to receive(:notify).with(instance_of(ActiveRecord::RecordInvalid))

          put :refund, params: { id: @obfuscated_id, amount: "1000", format: :json }

          expect(response.parsed_body).to eq "success" => false, "message" => "Sorry, something went wrong."
          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    describe "#search" do
      it_behaves_like "authorize called for action", :get, :search do
        let(:record) { Purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:policy_method) { :index? }
      end

      it "returns some proper json" do
        product = create(:product, user: seller)
        create(:purchase, email: "bob@exampleabc.com", link: product, seller: product.user, created_at: 6.days.ago)
        create(:purchase, email: "jane@exampleefg.com", link: product, seller: product.user)
        create(:purchase, link: product, seller: product.user, full_name: "edgar abc gumstein")
        index_model_records(Purchase)

        get :search, params: { query: "bob" }
        expect(response.parsed_body.length).to eq 1
        expect(response.parsed_body[0]["email"]).to eq "bob@exampleabc.com"
      end

      it "returns results sorted by score" do
        product = create(:product, user: seller)
        purchases = [
          create(:purchase, email: "a@a.com", link: product, full_name: "John John"),
          create(:purchase, email: "a@a.com", link: product, full_name: "John John John"),
          create(:purchase, email: "a@a.com", link: product, full_name: "John")
        ]
        index_model_records(Purchase)

        get :search, params: { query: "john" }
        expect(response.parsed_body[0]["id"]).to eq purchases[1].external_id
        expect(response.parsed_body[1]["id"]).to eq purchases[0].external_id
        expect(response.parsed_body[2]["id"]).to eq purchases[2].external_id
      end

      it "supports pagination" do
        product = create(:product, user: seller)
        purchases = [
          create(:purchase, email: "bob@exampleabc.com", link: product, seller:, created_at: 6.days.ago),
          create(:purchase, email: "bob@exampleabc.com", link: product, seller:, created_at: 5.days.ago)
        ]
        stub_const("#{described_class}::SEARCH_RESULTS_PER_PAGE", 1)
        index_model_records(Purchase)

        get :search, params: { query: "bob" }
        expect(response.parsed_body.length).to eq 1
        expect(response.parsed_body[0]["id"]).to eq purchases[1].external_id
        get :search, params: { query: "bob", page: 2 }
        expect(response.parsed_body.length).to eq 1
        expect(response.parsed_body[0]["id"]).to eq purchases[0].external_id
      end

      it "does not return the recurring purchase" do
        product = create(:membership_product, user: seller, subscription_duration: :monthly)
        user = create(:user, email: "subuser@example.com", credit_card: create(:credit_card))
        subscription = create(:subscription, link: product, user:, created_at: 3.days.ago)
        create(:purchase, email: user.email, is_original_subscription_purchase: true, link: product, subscription:, purchaser: user)
        create(:purchase, email: user.email, is_original_subscription_purchase: false, link: product, subscription:, purchaser: user)
        index_model_records(Purchase)

        get :search, params: { query: "sub" }
        expect(response.parsed_body.length).to eq 1
        expect(response.parsed_body[0]["email"]).to eq "subuser@example.com"
        expect(response.parsed_body[0]["subscription_id"]).to eq subscription.external_id
      end

      it "does not return both gift purchases" do
        product = create(:product, user: seller)
        create(:purchase, link: product, seller:, purchase_state: "successful")
        gifter_email = "gifter@foo.com"
        giftee_email = "giftee@domain.org"
        gift = create(:gift, gifter_email:, giftee_email:, link: product)
        gifter_purchase = create(:purchase, link: product,
                                            seller:,
                                            price_cents: product.price_cents,
                                            email: gifter_email,
                                            purchase_state: "successful",
                                            is_gift_sender_purchase: true,
                                            stripe_transaction_id: "ch_zitkxbhds3zqlt",
                                            can_contact: true)

        gift.gifter_purchase = gifter_purchase

        gift.giftee_purchase = create(:purchase, link: product,
                                                 seller:,
                                                 email: giftee_email,
                                                 price_cents: 0,
                                                 is_gift_receiver_purchase: true,
                                                 purchase_state: "gift_receiver_purchase_successful",
                                                 can_contact: true)
        gift.mark_successful
        gift.save!
        index_model_records(Purchase)

        get :search, params: { query: giftee_email }

        expect(response.parsed_body.length).to eq 1
        expect(response.parsed_body[0]["email"]).to eq giftee_email
      end

      it "includes variant details" do
        product = create(:product, user: seller)
        category = create(:variant_category, link: product, title: "Color")
        variant = create(:variant, variant_category: category, name: "Blue")
        create(:purchase, email: "bob@exampleabc.com", link: product, seller: product.user, created_at: 6.days.ago, variant_attributes: [variant])
        create(:purchase, email: "jane@exampleefg.com", link: product, seller: product.user)
        index_model_records(Purchase)

        get :search, params: { query: "bob" }

        expect(response.parsed_body[0]["variants"]).to eq ({
          category.external_id => {
            "title" => category.title,
            "selected_variant" => {
              "id" => variant.external_id,
              "name" => variant.name
            }
          }
        })
      end

      context "for subscriptions that have been upgraded" do
        before do
          setup_subscription
        end

        it "includes the upgraded purchase" do
          seller = @product.user
          @original_purchase.update!(full_name: "Sally Gumroad")

          travel_to(@originally_subscribed_at + 1.month) do
            params = {
              price_id: @yearly_product_price.external_id,
              variants: [@original_tier.external_id],
              use_existing_card: true,
              perceived_price_cents: @original_tier_yearly_price.price_cents,
              perceived_upgrade_price_cents: @original_tier_yearly_upgrade_cost_after_one_month,
            }

            result =
              Subscription::UpdaterService.new(subscription: @subscription,
                                               gumroad_guid: "abc123",
                                               params:,
                                               logged_in_user: @user,
                                               remote_ip: "1.1.1.1").perform

            expect(result[:success]).to eq true

            index_model_records(Purchase)

            sign_in seller

            get :search, params: { query: "sally" }


            expect(response.parsed_body.length).to eq 1
            expect(response.parsed_body[0]["purchase_email"]).to eq @original_purchase.email
          end
        end
      end
    end

    describe "change_can_contact" do
      before do
        @product = create(:product, user: seller)
        @purchase = create(:purchase, link: @product)
      end

      it_behaves_like "authorize called for action", :post, :change_can_contact do
        let(:record) { @purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: ObfuscateIds.encrypt(@purchase.id) } }
      end

      it "changes can_contact and returns HTTP success" do
        expect do
          post :change_can_contact, params: { id: @purchase.external_id, can_contact: false }
        end.to change { @purchase.reload.can_contact }.from(true).to(false)
        expect(response).to be_successful

        expect do
          post :change_can_contact, params: { id: @purchase.external_id, can_contact: true }
        end.to change { @purchase.reload.can_contact }.from(false).to(true)
        expect(response).to be_successful

        expect do
          post :change_can_contact, params: { id: @purchase.external_id, can_contact: true }
        end.to_not change { @purchase.reload.can_contact }
        expect(response).to be_successful
      end
    end

    describe "POST cancel_preorder_by_seller" do
      let(:purchase) { create(:preorder_authorization_purchase, price_cents: 300) }
      let(:seller) { purchase.seller }

      it_behaves_like "authorize called for action", :post, :cancel_preorder_by_seller do
        let(:record) { purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: ObfuscateIds.encrypt(purchase.id) } }
      end

      it "returns 404 json for invalid purchase" do
        expect do
          post :cancel_preorder_by_seller, params: { id: ObfuscateIds.encrypt(999_999) }
        end.to raise_error(ActionController::RoutingError, "Not Found")
      end

      context "with successful preorder" do
        let(:preorder_link) { create(:preorder_link, link: purchase.link) }

        before do
          preorder = create(:preorder, preorder_link:, seller:, state: "authorization_successful")
          purchase.update!(preorder:)
        end

        it "cancels the preorder" do
          post :cancel_preorder_by_seller, params: { id: ObfuscateIds.encrypt(purchase.id) }

          expect(response.parsed_body["success"]).to be(true)
          expect(purchase.preorder.reload.state).to eq("cancelled")
        end
      end
    end

    describe "GET export" do
      let(:params) { {} }

      before do
        @product = create(:product, user: seller, custom_fields: [create(:custom_field, name: "Height"), create(:custom_field, name: "Age")])
        @purchase_1 = create(:purchase, link: @product, purchase_custom_fields: [build(:purchase_custom_field, name: "Age", value: "25")])
        @purchase_2 = create(:purchase, link: @product, purchase_custom_fields: [build(:purchase_custom_field, name: "Citizenship", value: "Japan")])
        @purchase_3 = create(:purchase, link: build(:product, user: seller))
        create(:purchase)
        index_model_records(Purchase)
      end

      def expect_correct_csv(csv_string)
        csv = CSV.parse(csv_string)
        expect(csv.size).to eq(5)
        expect(csv[0]).to eq(Exports::PurchaseExportService::PURCHASE_FIELDS + ["Age", "Height", "Citizenship"])
        # Test the correct purchase is listed with the expected custom fields values.
        expect([csv[1].first] + csv[1].last(3)).to eq([@purchase_1.external_id, "25", nil, nil])
        expect([csv[2].first] + csv[2].last(3)).to eq([@purchase_2.external_id, nil, nil, "Japan"])
        expect([csv[3].first] + csv[3].last(3)).to eq([@purchase_3.external_id, nil, nil, nil])
        expect([csv[4].first] + csv[4].last(3)).to eq(["Totals", nil, nil, nil])
      end

      it_behaves_like "authorize called for action", :get, :export do
        let(:record) { Purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:policy_method) { :index? }
      end

      context "when number of sales is larger than threshold" do
        before do
          stub_const("Exports::PurchaseExportService::SYNCHRONOUS_EXPORT_THRESHOLD", 1)
        end

        it "queues sidekiq job and redirects back" do
          request.env["HTTP_REFERER"] = "/customers"
          get :export

          export = SalesExport.last!
          expect(export.recipient).to eq(user_with_role_for_seller)

          expect(Exports::Sales::CreateAndEnqueueChunksWorker).to have_enqueued_sidekiq_job(export.id)
          expect(flash[:warning]).to eq("You will receive an email in your inbox with the data you've requested shortly.")
          expect(response).to redirect_to("/customers")
        end

        context "when running sidekiq jobs" do
          it "results with the expected compiled CSV being emailed", :sidekiq_inline do
            stub_const("Exports::Sales::CreateAndEnqueueChunksWorker::MAX_PURCHASES_PER_CHUNK", 2)
            get :export

            email = ActionMailer::Base.deliveries.last
            expect(email.to).to eq([user_with_role_for_seller.email])

            expect_correct_csv(email.body.parts.last.body.to_s)
          end
        end

        context "when admin is signed in and impersonates seller" do
          before do
            @admin_user = create(:admin_user)
            sign_in @admin_user
            controller.impersonate_user(seller)
          end

          it "queues sidekiq job for the admin" do
            get :export

            export = SalesExport.last!
            expect(export.recipient).to eq(@admin_user)

            expect(Exports::Sales::CreateAndEnqueueChunksWorker).to have_enqueued_sidekiq_job(export.id)
            expect(flash[:warning]).to eq("You will receive an email in your inbox with the data you've requested shortly.")
            expect(response).to redirect_to("/customers")
          end
        end
      end

      context "when sales data is smaller than threshold" do
        it "sends data as CSV" do
          get :export
          expect(response.header["Content-Type"]).to include "text/csv"
          expect_correct_csv(response.body.to_s)
        end

        it "sends data as CSV with purchases in the correct order", :elasticsearch_wait_for_refresh do
          # We don't expect ES to return documents in any specific order,
          # because we expect the purchases.find_each in #purchases_data to order them.
          # The following lines manufactures a situation where ES will return purchase_2 after purchase_3:
          @purchase_2.__elasticsearch__.delete_document
          @purchase_2.__elasticsearch__.index_document
          get :export
          expect(response.header["Content-Type"]).to include "text/csv"
          expect_correct_csv(response.body.to_s)
        end
      end

      it "can filter by products and variants" do
        category = create(:variant_category, link: create(:product, user: seller))
        variant = create(:variant, variant_category: category)
        variant_purchase = create(:purchase, link: category.link, variant_attributes: [variant])
        index_model_records(Purchase)

        # response.body.lines.size - 2 => all lines without CSV header and totals
        get :export, params: {}
        expect(response.body.lines.size - 2).to eq(seller.sales.count)

        get :export, params: { product_ids: [], variant_ids: [] }
        expect(response.body.lines.size - 2).to eq(seller.sales.count)

        get :export, params: { product_ids: [@purchase_3.link.external_id], variant_ids: [] }
        expect(response.body.lines.size - 2).to eq(1)
        expect(response.body).to include(@purchase_3.external_id)

        get :export, params: { product_ids: [], variant_ids: [variant.external_id] }
        expect(response.body.lines.size - 2).to eq(1)
        expect(response.body).to include(variant_purchase.external_id)

        get :export, params: { product_ids: [seller.products.first.external_id], variant_ids: [variant.external_id] }
        expect(response.body.lines.size - 2).to eq(3)
        expect(response.body).to include(@purchase_1.external_id)
        expect(response.body).to include(@purchase_2.external_id)
        expect(response.body).not_to include(@purchase_3.external_id)
        expect(response.body).to include(variant_purchase.external_id)
      end

      it "filters out non-charged sales, and sales from other sellers" do
        create(:purchase)
        create(:failed_purchase, link: @product)
        create(:purchase, link: @product, purchase_state: "not_charged")
        index_model_records(Purchase)

        get :export
        expect(response.body.lines.size - 2).to eq(seller.sales.successful.count)
      end

      it "includes not_charged free trial purchases" do
        free_trial_membership_purchase = create(:free_trial_membership_purchase, link: create(:membership_product, :with_free_trial_enabled, user: seller))
        index_model_records(Purchase)

        get :export
        expect(response.body.lines.size - 2).to eq(seller.sales.successful.count + 1)
        expect(response.body).to include(free_trial_membership_purchase.external_id)
      end

      it "transforms the submitted start_time / end_time in the seller's time zone" do
        # Simulates someone's browser being in California (-07:00, ignored) while their TZ is in Japan (+09:00)
        seller.update!(timezone: "Tokyo")

        expect(PurchaseSearchService).to receive(:new).with(
          hash_including(
            created_on_or_after: Time.utc(2020, 7, 31, 15),
            created_before: Time.utc(2020, 8, 31, 14).end_of_hour,
        )).and_call_original

        params[:start_time] = "2020-08-01"
        params[:end_time] = "2020-08-31"
        get :export, params:
      end
    end

    describe "PUT revoke_access" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product, seller:) }

      it_behaves_like "authorize called for action", :put, :revoke_access do
        let(:record) { purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: purchase.external_id } }
        let(:request_format) { :json }
      end

      it "updates purchase and returns HTTP success" do
        put :revoke_access, params: { id: purchase.external_id }, as: :json

        expect(purchase.reload.is_access_revoked).to eq(true)
        expect(response).to be_successful
      end
    end

    describe "PUT undo_revoke_access" do
      let(:product) { create(:product, user: seller) }
      let(:purchase) { create(:purchase, link: product, seller:, is_access_revoked: true) }

      it_behaves_like "authorize called for action", :put, :undo_revoke_access do
        let(:record) { purchase }
        let(:policy_klass) { Audience::PurchasePolicy }
        let(:request_params) { { id: purchase.external_id } }
        let(:request_format) { :json }
      end

      it "updates purchase and returns HTTP success" do
        put :undo_revoke_access, params: { id: purchase.external_id }, as: :json
        expect(purchase.reload.is_access_revoked).to eq(false)
        expect(response).to be_successful
      end
    end
  end

  context "within consumer area" do
    describe "POST resend_receipt" do
      before do
        @product = create(:product)
        @purchase = create(:purchase, link: @product)
      end

      it "resends the receipt and returns true" do
        post :resend_receipt, params: { id: ObfuscateIds.encrypt(@purchase.id) }
        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@purchase.id).on("critical")
        expect(response).to be_successful
      end

      describe "gift purchase" do
        before do
          @product = create(:product_with_pdf_file)
          gifter_email = "gifter@foo.com"
          giftee_email = "giftee@foo.com"
          gift = create(:gift, gifter_email:, giftee_email:, link: @product)

          @gifter_purchase = create(:purchase,
                                    link: @product,
                                    seller: @product.user,
                                    price_cents: @product.price_cents,
                                    email: gifter_email,
                                    purchase_state: "successful")
          gift.gifter_purchase = @gifter_purchase
          @gifter_purchase.is_gift_sender_purchase = true
          @gifter_purchase.save!

          @giftee_purchase = gift.giftee_purchase = create(:purchase, link: @product,
                                                                      seller: @product.user,
                                                                      email: giftee_email,
                                                                      price_cents: 0,
                                                                      total_transaction_cents: 0,
                                                                      stripe_transaction_id: nil,
                                                                      stripe_fingerprint: nil,
                                                                      is_gift_receiver_purchase: true,
                                                                      purchase_state: "gift_receiver_purchase_successful")
          @giftee_purchase.create_url_redirect!

          gift.mark_successful
          gift.save!
        end

        it "resends the receipt to both gifter and giftee for gift purchases" do
          post :resend_receipt, params: { id: ObfuscateIds.encrypt(@gifter_purchase.id) }
          expect(response).to be_successful

          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@gifter_purchase.id).on("critical")
          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@giftee_purchase.id).on("critical")
        end

        context "when the product has stampable PDFs" do
          before do
            allow_any_instance_of(Link).to receive(:has_stampable_pdfs?).and_return(true)
          end

          it "enqueues receipt jobs on default queue" do
            post :resend_receipt, params: { id: ObfuscateIds.encrypt(@gifter_purchase.id) }
            expect(response).to be_successful

            expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@gifter_purchase.id).on("default")
            expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@giftee_purchase.id).on("default")
          end
        end
      end
    end

    describe "POST confirm" do
      let(:chargeable) { build(:chargeable, card: StripePaymentMethodHelper.success_sca_not_required) }
      let(:purchase) { create(:purchase_in_progress, chargeable:, was_product_recommended: true, recommended_by: "discover") }
      before do
        allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
        purchase.process!
      end

      context "when purchase was marked as failed" do
        before do
          purchase.mark_failed!
        end

        it "renders an error" do
          post :confirm, params: {
            id: purchase.external_id
          }

          expect(ChargeProcessor).not_to receive(:confirm_payment_intent!)

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("There is a temporary problem, please try again (your card was not charged).")
        end
      end

      context "when SCA fails" do
        it "marks purchase as failed and renders an error" do
          post :confirm, params: {
            id: purchase.external_id,
            stripe_error: {
              code: "invalid_request_error",
              message: "We are unable to authenticate your payment method."
            }
          }

          expect(purchase.reload.purchase_state).to eq("failed")

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("We are unable to authenticate your payment method.")
        end
      end

      context "when confirmation fails" do
        before do
          allow(ChargeProcessor).to receive(:confirm_payment_intent!).and_raise(ChargeProcessorUnavailableError)
        end

        it "marks purchase as failed and renders an error" do
          post :confirm, params: { id: purchase.external_id }

          expect(purchase.reload.purchase_state).to eq("failed")

          expect(response.parsed_body["success"]).to eq(false)
          expect(response.parsed_body["error_message"]).to eq("There is a temporary problem, please try again (your card was not charged).")
        end

        it "does not delete the bundle cookie" do
          cookies["gumroad-bundle"] = "bundle cookie"

          post :confirm, params: { id: purchase.external_id }
          cookies.update(response.cookies)

          expect(cookies["gumroad-bundle"]).to be_present
        end
      end

      context "when confirmation succeeds" do
        before do
          allow_any_instance_of(Stripe::PaymentIntent).to receive(:confirm)
        end

        it "confirms the purchase" do
          expect(purchase.reload.successful?).to eq(false)
          expect(Purchase::ConfirmService).to receive(:new).with(hash_including(purchase:)).and_call_original

          post :confirm, params: { id: purchase.external_id }
          expect(response.parsed_body["success"]).to eq(true)

          expect(response.parsed_body).to eq(purchase.reload.purchase_response.as_json)

          expect(purchase.reload.successful?).to eq(true)
        end

        context "when pre-order purchase" do
          let(:product) { create(:product_with_files, is_in_preorder_state: true) }
          let(:preorder_product) { create(:preorder_link, link: product, release_at: 25.hours.from_now) }
          let(:purchase) { create(:purchase_in_progress, link: product, chargeable:, is_preorder_authorization: true) }

          before do
            preorder = preorder_product.build_preorder(purchase)
            preorder.save!
          end

          it "marks pre-order authorized" do
            expect(Purchase::ConfirmService).to receive(:new).with(hash_including(purchase:)).and_call_original

            post :confirm, params: { id: purchase.external_id }
            expect(response.parsed_body["success"]).to eq(true)

            expect(response.parsed_body).to eq(purchase.reload.purchase_response.as_json)

            expect(purchase.reload.purchase_state).to eq("preorder_authorization_successful")
            expect(purchase.preorder.state).to eq("authorization_successful")
          end
        end

        it "creates a purchase event" do
          expect do
            post :confirm, params: { id: purchase.external_id }

            event = Event.last
            expect(event.purchase_id).to eq(purchase.id)
            expect(event.link_id).to eq(purchase.link_id)
            expect(event.event_name).to eq("purchase")
            expect(event.purchase_state).to eq("successful")
            expect(event.price_cents).to eq(purchase.price_cents)
            expect(event.was_product_recommended?).to eq(true)
          end.to change { Event.count }.by(1)
        end

        it "creates recommended purchase info" do
          expect do
            post :confirm, params: { id: purchase.external_id }
            purchase.reload
            expect(purchase.recommended_purchase_info.recommendation_type).to eq("discover")
            expect(purchase.recommended_purchase_info.discover_fee_per_thousand).to eq(100)
            expect(purchase.discover_fee_per_thousand).to eq(100)
          end.to change { RecommendedPurchaseInfo.count }.by(1)
        end
      end
    end

    describe "PUT update_subscription" do
      before do
        setup_subscription
        cookies.encrypted[@subscription.cookie_key] = @subscription.external_id
      end

      let(:params) do
        {
          id: @subscription.external_id,
          price_id: @yearly_product_price.external_id,
          variants: [@new_tier.external_id],
          perceived_price_cents: @new_tier_yearly_price.price_cents,
          perceived_upgrade_price_cents: @new_tier_yearly_upgrade_cost_after_one_month,
          contact_info: {
            email: @email,
            full_name: "Jane Gumroad",
            street_address: "100 Main St",
            city: "San Francisco",
            state: "CA",
            country: "US",
            zip_code: "00000",
          },
        }
      end
      let(:recaptcha_response) { "something" }
      let(:params_new_card) do
        params.merge(StripePaymentMethodHelper.success.to_stripejs_params(prepare_future_payments: true).merge("g-recaptcha-response" => recaptcha_response))
      end
      let(:params_existing_card) do
        params.merge(use_existing_card: true)
      end

      it "updates the variant, price, and contact information associated with the subscription" do
        travel_to(@originally_subscribed_at + 1.month) do
          put :update_subscription, params: params_new_card

          expect(response.parsed_body["success"]).to eq true
          expect(response.parsed_body["success_message"]).to eq "Your membership has been updated."

          updated_purchase = @subscription.reload.original_purchase

          expect(updated_purchase.variant_attributes).to eq [@new_tier]
          expect(updated_purchase.displayed_price_cents).to eq 20_00
          expect(updated_purchase.email).to eq @email
          expect(updated_purchase.full_name).to eq "Jane Gumroad"
          expect(updated_purchase.street_address).to eq "100 Main St"
          expect(updated_purchase.city).to eq "San Francisco"
          expect(updated_purchase.state).to eq "CA"
          expect(updated_purchase.country).to eq "United States"
          expect(updated_purchase.zip_code).to eq "00000"
        end
      end

      context "when encrypted cookie is not present" do
        before do
          cookies.encrypted[@subscription.cookie_key] = nil
        end

        it "raises ActionController::RoutingError" do
          expect do
            put :update_subscription, params: params_existing_card
          end.to raise_error(ActionController::RoutingError)
        end
      end

      describe "reCAPTCHA behavior" do
        it "does not attempt to verify the Google reCAPTCHA verification if using an existing card" do
          expect_any_instance_of(PurchasesController).not_to receive(:valid_recaptcha_response_and_hostname?)

          expect do
            travel_to(@originally_subscribed_at + 1.month) do
              put :update_subscription, params: params_existing_card
            end
          end.to change(Purchase.successful, :count)
        end

        it "verifies the Google reCAPTCHA verification if using a new card" do
          expect_any_instance_of(PurchasesController).to receive(:valid_recaptcha_response_and_hostname?).and_return(true)

          expect do
            travel_to(@originally_subscribed_at + 1.month) do
              put :update_subscription, params: params_new_card
            end
          end.to change(Purchase.successful, :count)
        end

        it "does not attempt to verify the Google reCAPTCHA verification if using a new card but upgrade price is 0" do
          expect_any_instance_of(PurchasesController).not_to receive(:valid_recaptcha_response_and_hostname?)

          same_plan_params = {
            id: @subscription.external_id,
            price_id: @quarterly_product_price.external_id,
            variants: [@original_tier.external_id],
            perceived_price_cents: @original_tier_quarterly_price.price_cents,
            perceived_upgrade_price_cents: 0,
          }.merge(StripePaymentMethodHelper.success.to_stripejs_params).merge("g-recaptcha-response" => recaptcha_response)

          expect do
            travel_to(@originally_subscribed_at + 1.month) do
              put :update_subscription, params: same_plan_params
            end
          end.not_to change(Purchase.successful, :count)
        end

        it "does not allow the purchase to proceed if reCAPTCHA verification fails" do
          expect_any_instance_of(PurchasesController).to receive(:valid_recaptcha_response_and_hostname?).and_return(false)

          expect do
            travel_to(@originally_subscribed_at + 1.month) do
              put :update_subscription, params: params_new_card
            end
          end.not_to change(Purchase.successful, :count)

          expect(response).to be_successful
          expect(response.parsed_body["success"]).to eq false
          expect(response.parsed_body["error_message"]).to eq "Sorry, we could not verify the CAPTCHA. Please try again."
        end
      end
    end

    describe "subscribe" do
      it "404s on bad subscribe" do
        expect { get :subscribe, params: { id: "notreal" } }.to raise_error(ActionController::RoutingError)
      end

      it "only sets can_contact to true" do
        purchase = create(:purchase, can_contact: false)
        get :subscribe, params: { id: purchase.external_id }
        expect(response).to be_successful
        expect(purchase.reload.can_contact).to eq true

        purchase2 = create(:purchase, can_contact: true)
        get :subscribe, params: { id: purchase2.external_id }
        expect(response).to be_successful
        expect(purchase2.reload.can_contact).to eq true
      end

      it "sets can_contact to true for all purchases" do
        purchase = create(:purchase, can_contact: true)
        purchase2 = create(:purchase, seller_id: purchase.seller.id, link: create(:product, user: purchase.seller), email: purchase.email, can_contact: true)
        get :subscribe, params: { id: purchase.external_id }
        expect(response).to be_successful
        expect(purchase.reload.can_contact).to eq true
        expect(purchase2.reload.can_contact).to eq true
      end
    end

    describe "unsubscribe" do
      it "404s on bad unsubscribe" do
        expect { get :unsubscribe, params: { id: "notreal" } }.to raise_error(ActionController::RoutingError)
      end

      context "with secure_external_id" do
        it "sets can_contact to false for all purchases from same seller and email" do
          purchase = create(:purchase, can_contact: true)
          purchase2 = create(:purchase, seller_id: purchase.seller.id, link: create(:product, user: purchase.seller), email: purchase.email, can_contact: true)
          secure_id = purchase.secure_external_id(scope: "unsubscribe")
          get :unsubscribe, params: { id: secure_id }
          expect(response).to be_successful
          expect(purchase.reload.can_contact).to eq false
          expect(purchase2.reload.can_contact).to eq false
        end

        context "with confirmation_text from secure_redirect_controller" do
          it "handles correct confirmation_text" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com")
            secure_id = purchase.secure_external_id(scope: "unsubscribe")
            get :unsubscribe, params: { id: secure_id, confirmation_text: "test@example.com" }
            expect(response).to be_successful
            expect(purchase.reload.can_contact).to eq false
          end

          it "handles incorrect confirmation_text by checking charge ID" do
            charge = create(:charge)
            purchase = create(:purchase, can_contact: true, email: "test@example.com", charge:)
            secure_id = purchase.secure_external_id(scope: "unsubscribe")

            # This simulates the case where the secure_id corresponds to a charge ID rather than purchase ID
            allow(Purchase).to receive(:find_by_secure_external_id).and_return(purchase)

            # Create another purchase with same charge ID but different email
            other_purchase = create(:purchase, can_contact: true, email: "other@example.com")
            allow(Purchase).to receive(:find_by).with(id: charge.id).and_return(other_purchase)

            get :unsubscribe, params: { id: secure_id, confirmation_text: "other@example.com" }
            expect(response).to be_successful
            expect(other_purchase.reload.can_contact).to eq false
          end

          it "redirects to root path when confirmation_text doesn't match any associated email" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com", charge: create(:charge))
            secure_id = purchase.secure_external_id(scope: "unsubscribe")

            get :unsubscribe, params: { id: secure_id, confirmation_text: "wrong@example.com" }
            expect(response).to redirect_to(root_path)
          end

          it "redirects to root path when confirmation_text doesn't match and purchase has no charge" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com", charge: nil)
            secure_id = purchase.secure_external_id(scope: "unsubscribe")

            get :unsubscribe, params: { id: secure_id, confirmation_text: "wrong@example.com" }
            expect(response).to redirect_to(root_path)
          end
        end
      end

      context "with legacy external_id" do
        context "when purchase exists" do
          it "redirects to secure redirect page for confirmation" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com")
            get :unsubscribe, params: { id: purchase.external_id }

            expect(response).to be_redirect
            expect(response.location).to start_with(secure_url_redirect_url)
            expect(response.location).to include("encrypted_payload")
            expect(response.location).to include("message=Please+enter+your+email+address+to+unsubscribe")
            expect(response.location).to include("field_name=Email+address")
            expect(response.location).to include("error_message=Email+address+does+not+match")
          end

          it "includes correct destination URL in redirect params" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com")
            allow(SecureEncryptService).to receive(:encrypt).and_call_original

            get :unsubscribe, params: { id: purchase.external_id }

            expect(SecureEncryptService).to have_received(:encrypt).once
            # Verify that the encrypted payload contains the expected data
            encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
            decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
            expect(decrypted_payload["destination"]).to match(%r{/purchases/.*unsubscribe})
            expect(decrypted_payload["confirmation_texts"]).to include(purchase.email)
            expect(decrypted_payload["send_confirmation_text"]).to be(true)
          end

          it "includes encrypted purchase email for confirmation" do
            purchase = create(:purchase, can_contact: true, email: "test@example.com")
            allow(SecureEncryptService).to receive(:encrypt).and_call_original

            get :unsubscribe, params: { id: purchase.external_id }

            expect(SecureEncryptService).to have_received(:encrypt).once
            # Verify that the encrypted payload contains the expected data
            encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
            decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
            expect(decrypted_payload["confirmation_texts"]).to include(purchase.email)
          end
        end

        context "when charge exists with multiple successful purchases" do
          it "collects all emails from charge's successful purchases" do
            seller = create(:user)
            product = create(:product, user: seller)
            charge = create(:charge, seller: seller)
            create(:purchase, link: product, seller: seller, email: "buyer1@example.com", charge: charge, purchase_state: "successful")
            create(:purchase, link: product, seller: seller, email: "buyer2@example.com", charge: charge, purchase_state: "successful")

            allow(SecureEncryptService).to receive(:encrypt).and_call_original

            get :unsubscribe, params: { id: charge.external_id }

            expect(SecureEncryptService).to have_received(:encrypt).once
            # Verify that the encrypted payload contains all emails
            encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
            decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
            expect(decrypted_payload["confirmation_texts"]).to include("buyer1@example.com")
            expect(decrypted_payload["confirmation_texts"]).to include("buyer2@example.com")
          end

          it "handles case where charge external_id is used but purchase also exists" do
            seller = create(:user)
            product = create(:product, user: seller)
            charge = create(:charge, seller: seller)
            purchase = create(:purchase, link: product, seller: seller, email: "buyer@example.com", charge: charge, purchase_state: "successful")

            # Create a purchase with the same external_id as the charge (the bug scenario)
            allow(Purchase).to receive(:find_by_external_id).with(charge.external_id).and_return(purchase)
            allow(Charge).to receive(:find_by_external_id).with(charge.external_id).and_return(charge)

            allow(SecureEncryptService).to receive(:encrypt).and_call_original

            get :unsubscribe, params: { id: charge.external_id }

            expect(SecureEncryptService).to have_received(:encrypt).once
            # Verify that the encrypted payload contains the email
            encrypted_payload = URI.decode_www_form(URI.parse(response.location).query).to_h["encrypted_payload"]
            decrypted_payload = JSON.parse(SecureEncryptService.decrypt(encrypted_payload))
            expect(decrypted_payload["confirmation_texts"]).to include("buyer@example.com")
          end

          it "redirects to secure redirect when no purchase found but charge exists" do
            seller = create(:user)
            product = create(:product, user: seller)
            charge = create(:charge, seller: seller)
            create(:purchase, link: product, seller: seller, email: "buyer@example.com", charge: charge, purchase_state: "successful")

            allow(Purchase).to receive(:find_by_external_id).with(charge.external_id).and_return(nil)
            allow(Charge).to receive(:find_by_external_id).with(charge.external_id).and_return(charge)

            get :unsubscribe, params: { id: charge.external_id }

            expect(response).to be_redirect
            expect(response.location).to start_with(secure_url_redirect_url)
          end
        end

        context "when neither purchase nor charge exists" do
          it "returns 404 error" do
            expect do
              get :unsubscribe, params: { id: "invalid_id" }
            end.to raise_error(ActionController::RoutingError)
          end
        end
      end
    end

    describe "GET confirm_receipt_email" do
      let(:purchase) { create(:purchase) }

      it "renders the confirm_receipt_email template" do
        get :confirm_receipt_email, params: { id: purchase.external_id }
        expect(response).to be_successful
        expect(assigns(:purchase)).to eq(purchase)
        expect(assigns(:title)).to eq("Confirm Email")
        expect(assigns(:hide_layouts)).to be(true)
      end
    end



    describe "GET receipt" do
      let(:purchase) { create(:purchase, email: "test@example.com") }

      context "when email is not verified" do
        it "redirects to confirm_receipt_email page" do
          get :receipt, params: { id: purchase.external_id }
          expect(response).to redirect_to(confirm_receipt_email_purchase_path(purchase.external_id))
        end

        it "shows receipt when correct email is provided" do
          get :receipt, params: { id: purchase.external_id, email: "test@example.com" }
          expect(response).to be_successful
          expect(response.body).to match("Generate invoice")
        end

        it "redirects back to confirm_receipt_email when incorrect email is provided" do
          get :receipt, params: { id: purchase.external_id, email: "wrong@example.com" }
          expect(response).to redirect_to(confirm_receipt_email_purchase_path(purchase.external_id))
          expect(flash[:alert]).to eq("Wrong email. Please try again.")
        end

        it "is case insensitive when comparing emails" do
          get :receipt, params: { id: purchase.external_id, email: "TEST@example.com" }
          expect(response).to be_successful
        end

        it "trims whitespace from email input" do
          get :receipt, params: { id: purchase.external_id, email: " test@example.com " }
          expect(response).to be_successful
        end
      end

      context "when user is logged in as purchaser" do
        let(:user) { create(:user) }
        let(:purchase) { create(:purchase, email: "test@example.com", purchaser: user) }

        before do
          sign_in user
        end

        it "shows the receipt for the purchase" do
          get :receipt, params: { id: purchase.external_id }
          expect(response).to be_successful
          expect(response.body).to match("Generate invoice")
        end

        it "404s for an invalid id" do
          expect do
            get :receipt, params: { id: "1234" }
          end.to raise_error(ActionController::RoutingError)
        end

        it "adds X-Robots-Tag response header to avoid page indexing" do
          get :receipt, params: { id: purchase.external_id }
          expect(response).to be_successful
          expect(response.headers["X-Robots-Tag"]).to eq("noindex")
        end

        it "calls CustomerMailer with correct args" do
          expect(CustomerMailer).to receive(:receipt).with(purchase.id, for_email: false).and_call_original
          get :receipt, params: { id: purchase.external_id }
          expect(response).to be_successful
        end
      end

      context "when user is the purchaser" do
        let(:user) { create(:user) }
        let(:purchase) { create(:purchase, email: "test@example.com", purchaser: user) }

        before do
          sign_in user
        end

        it "renders the receipt without requiring email verification" do
          get :receipt, params: { id: purchase.external_id }
          expect(response).to be_successful
        end
      end

      context "when user is a team member" do
        let(:team_member) { create(:user) }
        let(:purchase) { create(:purchase, email: "test@example.com") }

        before do
          team_member.update!(is_team_member: true)
          sign_in team_member
        end

        it "renders the receipt without requiring email verification" do
          get :receipt, params: { id: purchase.external_id }
          expect(response).to be_successful
          expect(response.body).to match("Generate invoice")
        end
      end

      describe "View content button" do
        let(:purchase) { create(:purchase, email: "test@example.com") }

        before do
          purchase.create_url_redirect
        end

        it "renders View content button in English" do
          get :receipt, params: { id: purchase.external_id, email: purchase.email }
          expect(response).to be_successful
          expect(response.body).to have_text("View content")
        end
      end
    end

    describe "GET confirm_generate_invoice" do
      let(:purchase) { create(:purchase) }

      it "returns success" do
        get :confirm_generate_invoice, params: { id: purchase.external_id }

        expect(response).to be_successful
      end
    end

    describe "GET generate_invoice" do
      let(:date) { Time.find_zone("UTC").local(2024, 04, 10) }
      let(:seller) { create(:named_seller) }
      let(:product_one) { create(:product, user: seller, name: "Product One") }
      let(:purchase_one) { create(:purchase, created_at: date, link: product_one) }
      let(:purchase) { purchase_one }
      let(:params) { { id: purchase.external_id, email: purchase.email } }

      describe "for Purchase" do
        it "adds X-Robots-Tag response header to avoid page indexing" do
          get :generate_invoice, params: params
          expect(response.headers["X-Robots-Tag"]).to eq("noindex")
        end

        it "renders the page" do
          get :generate_invoice, params: params
          expect(response).to be_successful
          expect(response.body).to have_text("Generate invoice")
        end

        it "assigns the purchase as the chargeable for the presenter" do
          get :generate_invoice, params: params
          expect(assigns(:invoice_presenter).send(:chargeable)).to eq(purchase)
        end
      end

      describe "for Charge" do
        let(:product_two) { create(:product, user: seller, name: "Product Two") }
        let(:purchase_two) { create(:purchase, created_at: date, link: product_two) }
        let(:charge) { create(:charge, seller:, purchases: [purchase_one, purchase_two]) }
        let(:order) { charge.order }

        before do
          order.purchases << [purchase_one, purchase_two]
          order.update!(created_at: date)
        end

        it "assigns the charge as the chargeable for the presenter" do
          get :generate_invoice, params: params
          expect(assigns(:invoice_presenter).send(:chargeable)).to eq(charge)
        end

        context "when the second purchase is used as a param" do
          let(:purchase) { purchase_two }

          it "assigns the charge as the chargeable for the presenter" do
            get :generate_invoice, params: params
            expect(assigns(:invoice_presenter).send(:chargeable)).to eq(charge)
          end
        end

        context "when the email does not match with purchase's email" do
          context "when the email is not present in params" do
            it "redirects to email confirmation path" do
              get :generate_invoice, params: { id: purchase.external_id }

              expect(response).to redirect_to(confirm_generate_invoice_path(id: purchase.external_id))
              expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
            end
          end

          context "when the email is present in params" do
            it "redirects to email confirmation path" do
              get :generate_invoice, params: { id: purchase.external_id, email: "wrong-email@example.com" }

              expect(response).to redirect_to(confirm_generate_invoice_path(id: purchase.external_id))
              expect(flash[:alert]).to eq("Incorrect email address. Please try again.")
            end
          end
        end
      end
    end

    describe "POST send_invoice" do
      let(:date) { Time.find_zone("UTC").local(2024, 04, 10) }
      let(:seller) { create(:named_seller) }
      let(:product_one) { create(:product, user: seller, name: "Product One") }
      let(:purchase_one) { create(:purchase, created_at: date, link: product_one) }
      let(:purchase) { purchase_one }
      let(:payload) do
        {
          id: purchase.external_id,
          email: purchase.email,
          full_name: "Sri Raghavan",
          street_address: "367 Hermann St",
          city: "San Francisco",
          state: "CA",
          zip_code: "94103",
          country_code: "US"
        }
      end

      before :each do
        @s3_obj_public_url = "https://s3.amazonaws.com/gumroad-specs/attachment/manual.pdf"

        s3_obj_double = double
        allow(s3_obj_double).to receive(:presigned_url).and_return(@s3_obj_public_url)

        allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf) do |purchase, pdf|
          @generated_pdf = pdf
          s3_obj_double
        end
      end

      describe "for Purchase" do
        it "assigns the purchase as the chargeable" do
          post :send_invoice, params: payload
          expect(assigns(:chargeable)).to eq(purchase)
        end

        describe "when user is issuing an invoice" do
          it "returns success json response" do
            post :send_invoice, params: payload

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
          end

          it "returns unsuccessful json response if the process fails" do
            allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_raise("error")

            post :send_invoice, params: payload

            expect(response.parsed_body["success"]).to be(false)
          end

          it "returns unsuccessful json response if purchase doesn't exist" do
            expect do
              post :send_invoice, params: payload.merge!(id: "invalid")
            end.to raise_error(ActionController::RoutingError)
          end

          it "sends a PDF invoice with the purchase and payload details" do
            post :send_invoice, params: payload

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("United States")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end

          it "sends a PDF invoice with the purchase and payload details for non-US country" do
            post :send_invoice, params: payload.merge!(country_code: "JP")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Japan")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end

          it "sends a PDF invoice with the purchase and payload details for direct sales to AU customers" do
            allow_any_instance_of(Link).to receive(:is_physical?).and_return(true)
            allow_any_instance_of(Purchase).to receive(:country).and_return("Australia")

            post :send_invoice, params: payload.merge!(country_code: "AU")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include(purchase.seller.display_name)
            expect(pdf_text).to include(purchase.seller.email)
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Australia")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end
        end

        context "when user provides additional notes" do
          it "it includes additional notes in the invoice" do
            post :send_invoice, params: payload.merge(additional_notes: "Very important custom information.")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Additional notes")
            expect(pdf_text).to include("Very important custom information.")
          end
        end

        describe "when user provides a vat id" do
          before do
            @zip_tax_rate = create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false)
            @purchase = create(:purchase_in_progress, zip_tax_rate: @zip_tax_rate, chargeable: create(:chargeable))
            @purchase.process!
            @purchase.mark_successful!
            @purchase.gumroad_tax_cents = 20
            @purchase.save!
          end

          it "refunds tax" do
            post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax when provided an invalid vat id" do
            post :send_invoice, params: payload.merge(vat_id: "EU123456789", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid ABN id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "51824753556", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid ABN id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "11111111111", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid GST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "T9100001B", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid GST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "T9100001C", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid QST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::CAN.alpha2, state_code: QUEBEC)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "1002092821TQ0001", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid QST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::CAN.alpha2, state_code: QUEBEC)
            @purchase.update!(purchase_sales_tax_info:)

            post :send_invoice, params: payload.merge(vat_id: "NR00005576", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "does not refund tax but still send receipt if already refunded" do
            @purchase.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
            expect(Refund.count).to be(1)

            post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.count).to be(1)
          end

          it "returns error if purchase is not successful" do
            @purchase.update_attribute(:purchase_state, "in_progress")
            post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: @purchase.external_id, email: @purchase.email)

            expect(response.parsed_body["success"]).to be(false)
            expect(response.parsed_body["message"]).to eq("Your purchase has not been completed by PayPal yet. Please try again soon.")
            expect(Refund.count).to be(0)
          end
        end

        context "when the email param is not set" do
          it "redirects to the email confirmation path" do
            post :send_invoice, params: payload.except(:email)

            expect(response).to redirect_to(confirm_generate_invoice_path(purchase.external_id))
          end
        end
      end

      describe "for Charge" do
        let(:product_two) { create(:product, user: seller, name: "Product Two") }
        let(:purchase_two) { create(:purchase, created_at: date, link: product_two) }
        let(:charge) { create(:charge, seller:, purchases: [purchase_one, purchase_two]) }
        let(:order) { charge.order }

        before do
          order.purchases << [purchase_one, purchase_two]
          order.update!(created_at: date)
        end

        it "assigns the charge as the chargeable" do
          post :send_invoice, params: payload
          expect(assigns(:chargeable)).to eq(charge)
        end

        context "when the second purchase is used as a param" do
          let(:purchase) { purchase_two }

          it "assigns the charge as the chargeable" do
            post :send_invoice, params: payload
            expect(assigns(:chargeable)).to eq(charge)
          end
        end

        describe "when user is issuing an invoice" do
          it "returns success json response" do
            post :send_invoice, params: payload

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
          end

          it "returns unsuccessful json response if the process fails" do
            allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_raise("error")

            post :send_invoice, params: payload

            expect(response.parsed_body["success"]).to be(false)
          end

          it "returns unsuccessful json response if purchase doesn't exist" do
            expect do
              post :send_invoice, params: payload.merge!(id: "invalid")
            end.to raise_error(ActionController::RoutingError)
          end

          it "sends a PDF invoice with the purchase and payload details" do
            post :send_invoice, params: payload

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("United States")
            expect(pdf_text).to include(charge.order.email)
            expect(pdf_text).to match(/Product One.*\$1/)
            expect(pdf_text).to include("Product Two $1")
            expect(pdf_text).to include("Payment Total $2")
            expect(pdf_text).not_to include("Additional notes")
          end

          it "sends a PDF invoice with the purchase and payload details for non-US country" do
            post :send_invoice, params: payload.merge!(country_code: "JP")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Japan")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to match(/Product One.*\$1/)
            expect(pdf_text).to include("Product Two $1")
            expect(pdf_text).to include("Payment Total $2")
            expect(pdf_text).not_to include("Additional notes")
          end

          it "sends a PDF invoice with the purchase and payload details for direct sales to AU customers" do
            allow_any_instance_of(Link).to receive(:is_physical?).and_return(true)
            allow_any_instance_of(Purchase).to receive(:country).and_return("Australia")

            post :send_invoice, params: payload.merge!(country_code: "AU")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include(purchase.seller.display_name)
            expect(pdf_text).to include(purchase.seller.email)
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Australia")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include("Product One")
            expect(pdf_text).to include("$1")
            expect(pdf_text).to include("Product Two")
            expect(pdf_text).to include("$1")
            expect(pdf_text).to include("Payment Total")
            expect(pdf_text).to include("$2")
            expect(pdf_text).not_to include("Additional notes")
          end
        end

        context "when user provides additional notes" do
          it "it includes additional notes in the invoice" do
            post :send_invoice, params: payload.merge(additional_notes: "Very important custom information.")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Additional notes")
            expect(pdf_text).to include("Very important custom information.")
          end
        end

        describe "when user provides a vat id" do
          let(:zip_tax_rate) { create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false) }
          let(:purchase_one) do
            purchase = create(:purchase_in_progress, zip_tax_rate: zip_tax_rate, chargeable: create(:chargeable), link: product_one)
            purchase.process!
            purchase.mark_successful!
            purchase.update!(gumroad_tax_cents: 20, was_purchase_taxable: true)
            purchase
          end
          let(:purchase_two) do
            purchase = create(:purchase_in_progress, zip_tax_rate: zip_tax_rate, chargeable: create(:chargeable), link: product_two)
            purchase.process!
            purchase.mark_successful!
            purchase.update!(gumroad_tax_cents: 20, was_purchase_taxable: true)
            purchase
          end

          it "refunds tax" do
            expect(Refund.count).to be(0)
            expect do
              post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: purchase.external_id)
            end.to change(Refund, :count).by(2)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
          end

          it "does not refund tax when provided an invalid vat id" do
            expect do
              post :send_invoice, params: payload.merge(vat_id: "EU123456789", id: purchase.external_id)
            end.to_not change(Refund, :count)

            expect(response.parsed_body["success"]).to be(true)
            expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
          end

          context "with a valid ABN id" do
            before do
              purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
              purchase.update!(purchase_sales_tax_info:)
              purchase_two.update!(purchase_sales_tax_info:)
            end

            it "refunds tax" do
              expect do
                post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: purchase.external_id)
              end.to change(Refund, :count).by(2)

              expect(response.parsed_body["success"]).to be(true)
              expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
              expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
            end

            context "with an invalid ABN id" do
              it "does not refund tax" do
                expect do
                  post :send_invoice, params: payload.merge(vat_id: "11111111111", id: purchase.external_id)
                end.to_not change(Refund, :count)

                expect(response.parsed_body["success"]).to be(true)
                expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
              end
            end
          end

          context "with a valid GST id" do
            before do
              purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
              purchase.update!(purchase_sales_tax_info:, was_purchase_taxable: true)
            end

            it "refunds tax" do
              expect do
                post :send_invoice, params: payload.merge(vat_id: "T9100001B", id: purchase.external_id)
              end.to change(Refund, :count).by(2)

              expect(response.parsed_body["success"]).to be(true)
              expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
              expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
            end

            context "with an invalid GST id" do
              it "does not refund tax" do
                expect do
                  post :send_invoice, params: payload.merge(vat_id: "T9100001C", id: purchase.external_id)
                end.to_not change(Refund, :count)

                expect(response.parsed_body["success"]).to be(true)
                expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
              end
            end
          end

          context "when already refunded" do
            before do
              purchase.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
              purchase_two.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
            end

            it "does not refund tax" do
              expect(Refund.count).to be(2)
              expect do
                post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: purchase.external_id)
              end.to_not change(Refund, :count)

              expect(response.parsed_body["success"]).to be(true)
              expect(response.parsed_body["file_location"]).to eq(@s3_obj_public_url)
            end
          end

          context "when purchase is not successful" do
            before do
              purchase.update_attribute(:purchase_state, "in_progress")
              purchase_two.update_attribute(:purchase_state, "in_progress")
            end

            it "returns error if purchase is not successful" do
              post :send_invoice, params: payload.merge(vat_id: "IE6388047V", id: purchase.external_id)

              expect(response.parsed_body["success"]).to be(false)
              expect(response.parsed_body["message"]).to eq("Your purchase has not been completed by PayPal yet. Please try again soon.")
              expect(Refund.count).to be(0)
            end
          end
        end
      end
    end
  end
end
