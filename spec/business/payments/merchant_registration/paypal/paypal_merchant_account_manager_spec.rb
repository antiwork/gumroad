# frozen_string_literal: true

describe PaypalMerchantAccountManager, :vcr do
  describe "#create_partner_referral" do
    let(:user) { create(:user) }

    context "when partner referral request is successful" do
      before do
        @response = described_class.new.create_partner_referral(user, "http://redirecturl.com")
      end

      it "returns success response data" do
        expect(@response[:success]).to eq(true)
        expect(@response[:redirect_url]).to match("www.sandbox.paypal.com")
      end
    end

    context "when partner referral request fails" do
      before do
        allow_any_instance_of(described_class).to receive(:authorization_header).and_return(" ")
        @response = described_class.new.create_partner_referral(user, "http://redirecturl.com")
      end

      it "returns failure response data" do
        expect(@response[:success]).to eq(false)
        expect(@response[:error_message]).to eq("Please try again later.")
      end
    end
  end

  describe "handle_paypal_event" do
    context "when event type is #{PaypalEventType::MERCHANT_PARTNER_CONSENT_REVOKED}" do
      let(:paypal_event) do { "id" => "WH-59L56223MP7193543-0JE01801LE024204Y", "event_version" => "1.0",
                              "create_time" => "2017-09-29T04:45:38.473Z", "resource_type" => "partner-consent", "event_type" => "MERCHANT.PARTNER-CONSENT.REVOKED", "summary" => "The Account setup consents has been revoked or the merchant account is closed", "resource" => { "merchant_id" => "FQ9WM47T82UAS", "tracking_id" => "7674947449674" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-59L56223MP7193543-0JE01801LE024204Y", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-59L56223MP7193543-0JE01801LE024204Y/resend", "rel" => "resend", "method" => "POST" }], "foreign_webhook" => { "id" => "WH-59L56223MP7193543-0JE01801LE024204Y", "event_version" => "1.0", "create_time" => "2017-09-29T04:45:38.473Z", "resource_type" => "partner-consent", "event_type" => "MERCHANT.PARTNER-CONSENT.REVOKED", "summary" => "The Account setup consents has been revoked or the merchant account is closed", "resource" => { "merchant_id" => "FQ9WM47T82UAS", "tracking_id" => "7674947449674" }, "links" => [{ "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-59L56223MP7193543-0JE01801LE024204Y", "rel" => "self", "method" => "GET" }, { "href" => "https://api.sandbox.paypal.com/v1/notifications/webhooks-events/WH-59L56223MP7193543-0JE01801LE024204Y/resend", "rel" => "resend", "method" => "POST" }] } } end

      context "when merchant account is not present" do
        it "does nothing" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to raise_error
        end
      end

      context "when merchant account is present" do
        before do
          @merchant_account = create(:merchant_account_paypal, charge_processor_merchant_id: paypal_event["resource"]["merchant_id"])
        end

        it "marks the merchant account as deleted" do
          described_class.new.handle_paypal_event(paypal_event)
          @merchant_account.reload
          expect(@merchant_account.alive?).to be(false)
        end

        it "marks all the merchant accounts as deleted if there are more than one connected to the same paypal account" do
          merchant_account_2 = create(:merchant_account_paypal, charge_processor_merchant_id: paypal_event["resource"]["merchant_id"])

          described_class.new.handle_paypal_event(paypal_event)

          expect(@merchant_account.reload.alive?).to be(false)
          expect(merchant_account_2.reload.alive?).to be(false)
        end

        it "does nothing if there are no alive merchant accounts for the paypal account" do
          @merchant_account.mark_deleted!
          expect(@merchant_account.reload.alive?).to be(false)

          expect_any_instance_of(MerchantAccount).not_to receive(:delete_charge_processor_account!)
          expect(MerchantRegistrationMailer).not_to receive(:account_deauthorized_to_user)
          described_class.new.handle_paypal_event(paypal_event)
        end

        context "when user is merchant migration enabled" do
          before do
            @user = @merchant_account.user
            @user.update_attribute(:check_merchant_account_is_linked, true)
            create(:user_compliance_info, user: @user)
            @product = create(:product_with_pdf_file, purchase_disabled_at: Time.current, user: @user)
            @product.publish!
          end

          it "marks the merchant account as deleted and disables sales" do
            expect(MerchantRegistrationMailer).to receive(:account_deauthorized_to_user).with(
              @user.id,
              @merchant_account.charge_processor_id
            ).and_call_original

            described_class.new.handle_paypal_event(paypal_event)
            @product.reload
            expect(@product.purchase_disabled_at).to be_nil
          end
        end
      end
    end

    context "when event type is #{PaypalEventType::MERCHANT_ONBOARDING_COMPLETED}" do
      context "when tracking_id is absent in the webhook payload" do
        let(:paypal_event) { { "id" => "WH-4WS08821J7410062M-6JM26615AM999645H", "event_version" => "1.0", "create_time" => "2021-01-09T17:43:54.797Z", "resource_type" => "merchant-onboarding", "event_type" => "MERCHANT.ONBOARDING.COMPLETED", "summary" => "The merchant account setup is completed", "resource" => { "partner_client_id" => "AeuUyDUbnlHJnLRfnK2RUSl4BlaVSyRtBpoaak7YeCyZv1dcFjAAgWHUTiGAmRCDfkCwLaOrHgdT2Apv", "links" => [{ "method" => "GET", "rel" => "self", "description" => "Get the merchant status information of merchants onboarded by this partner", "href" => "https://api.paypal.com/v1/customer/partners/Y9TEHAMRZ4T7L/merchant-integrations/V74ZDABEJCZ7C" }], "merchant_id" => "V74ZDABEJCZ7C" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4WS08821J7410062M-6JM26615AM999645H", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4WS08821J7410062M-6JM26615AM999645H/resend", "rel" => "resend", "method" => "POST" }], "foreign_webhook" => { "id" => "WH-4WS08821J7410062M-6JM26615AM999645H", "event_version" => "1.0", "create_time" => "2021-01-09T17:43:54.797Z", "resource_type" => "merchant-onboarding", "event_type" => "MERCHANT.ONBOARDING.COMPLETED", "summary" => "The merchant account setup is completed", "resource" => { "partner_client_id" => "AeuUyDUbnlHJnLRfnK2RUSl4BlaVSyRtBpoaak7YeCyZv1dcFjAAgWHUTiGAmRCDfkCwLaOrHgdT2Apv", "links" => [{ "method" => "GET", "rel" => "self", "description" => "Get the merchant status information of merchants onboarded by this partner", "href" => "https://api.paypal.com/v1/customer/partners/Y9TEHAMRZ4T7L/merchant-integrations/V74ZDABEJCZ7C" }], "merchant_id" => "V74ZDABEJCZ7C" }, "links" => [{ "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4WS08821J7410062M-6JM26615AM999645H", "rel" => "self", "method" => "GET" }, { "href" => "https://api.paypal.com/v1/notifications/webhooks-events/WH-4WS08821J7410062M-6JM26615AM999645H/resend", "rel" => "resend", "method" => "POST" }] } } }

        it "does nothing" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to raise_error
        end
      end

      context "when merchant account record is not present" do
        let!(:user) { create(:user) }
        let(:paypal_event) do { "event_type" => PaypalEventType::MERCHANT_ONBOARDING_COMPLETED,
                                "resource" => { "merchant_id" => "GSQ5PDPXZCWGW",
                                                "tracking_id" => user.external_id } } end

        it "does not create a new merchant account record" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to change { MerchantAccount.count }
        end
      end
    end

    context "when event type is #{PaypalEventType::MERCHANT_CAPABILITY_UPDATED}" do
      let(:paypal_event) do { "event_type" => PaypalEventType::MERCHANT_CAPABILITY_UPDATED,
                              "resource" => { "merchant_id" => "GSQ5PDPXZCWGW",
                                              "tracking_id" => create(:user).external_id } } end

      context "when merchant account record is not present" do
        it "does not create a new merchant account record" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to change { MerchantAccount.count }
        end
      end

      context "when merchant account record is present" do
        before do
          @merchant_account = create(:merchant_account_paypal,
                                     charge_processor_merchant_id: paypal_event["resource"]["merchant_id"],
                                     user: User.find_by_external_id(paypal_event["resource"]["tracking_id"]))
          @merchant_account.user.mark_compliant!(author_name: "ContentModeration")
          allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
          create(:payment_completed, user: @merchant_account.user)
        end

        it "does not re-enable if merchant account is deleted" do
          @merchant_account.mark_deleted!
          expect(@merchant_account.reload.alive?).to be(false)

          described_class.new.handle_paypal_event(paypal_event)

          expect(@merchant_account.reload.alive?).to be(false)
        end

        it "updates the merchant account if it is not deleted" do
          @merchant_account.charge_processor_deleted_at = 1.day.ago
          @merchant_account.save!
          expect(@merchant_account.alive?).to be(true)
          expect(@merchant_account.charge_processor_alive?).to be(false)

          described_class.new.handle_paypal_event(paypal_event)

          @merchant_account.reload
          expect(@merchant_account.alive?).to be(true)
          expect(@merchant_account.charge_processor_alive?).to be(true)
        end
      end
    end

    context "when event type is #{PaypalEventType::MERCHANT_SUBSCRIPTION_UPDATED}" do
      context "when merchant account record is not present" do
        let(:paypal_event) do { "event_type" => PaypalEventType::MERCHANT_SUBSCRIPTION_UPDATED,
                                "resource" => { "merchant_id" => "FQ9WM47T82UAS",
                                                "tracking_id" => create(:user).external_id } } end

        it "does not create a new merchant account record" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to change { MerchantAccount.count }
        end
      end
    end

    context "when event type is #{PaypalEventType::MERCHANT_EMAIL_CONFIRMED}" do
      context "when merchant account record is not present" do
        let(:paypal_event) do { "event_type" => PaypalEventType::MERCHANT_EMAIL_CONFIRMED,
                                "resource" => { "merchant_id" => "FQ9WM47T82UAS",
                                                "tracking_id" => create(:user).external_id } } end

        it "does not create a new merchant account record" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to change { MerchantAccount.count }
        end
      end
    end

    context "when event type is #{PaypalEventType::MERCHANT_ONBOARDING_SELLER_GRANTED_CONSENT}" do
      context "when merchant account record is not present" do
        let(:paypal_event) do { "event_type" => PaypalEventType::MERCHANT_ONBOARDING_SELLER_GRANTED_CONSENT,
                                "resource" => { "merchant_id" => "FQ9WM47T82UAS",
                                                "tracking_id" => create(:user).external_id } } end

        it "does not create a new merchant account record" do
          expect do
            described_class.new.handle_paypal_event(paypal_event)
          end.not_to change { MerchantAccount.count }
        end
      end
    end
  end

  describe "#update_merchant_account" do
    it "sends a confirmation email when the paypal connect account is updated" do
      creator = create(:user)
      creator.mark_compliant!(author_name: "ContentModeration")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
      create(:payment_completed, user: creator)
      expect(MerchantRegistrationMailer).to receive(:paypal_account_updated).with(creator.id).and_call_original
      expect do
        subject.update_merchant_account(user: creator, paypal_merchant_id: "GSQ5PDPXZCWGW")
      end.to change { creator.merchant_accounts.charge_processor_verified.paypal.count }.by(1)
    end

    it "does not send a confirmation email when the paypal connect account info is not changed" do
      creator = create(:user)
      create(:merchant_account_paypal, charge_processor_merchant_id: "GSQ5PDPXZCWGW", user: creator,
                                       charge_processor_alive_at: 1.hour.ago, charge_processor_verified_at: 1.hour.ago)

      expect(MerchantRegistrationMailer).not_to receive(:paypal_account_updated).with(creator.id)
      expect do
        subject.update_merchant_account(user: creator, paypal_merchant_id: "GSQ5PDPXZCWGW")
      end.not_to change { MerchantAccount.count }
    end

    context "when oauth_integrations is missing from the PayPal response" do
      let(:creator) { create(:user) }
      let(:paypal_merchant_id) { "GSQ5PDPXZCWGW" }

      before do
        creator.mark_compliant!(author_name: "ContentModeration")
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
        create(:payment_completed, user: creator)
        allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(
          "country" => "US",
          "primary_currency" => "USD",
          "primary_email_confirmed" => true,
          "payments_receivable" => true,
          "primary_email" => "seller@example.com"
        )
      end

      it "treats the account as incomplete instead of raising NoMethodError" do
        result = subject.update_merchant_account(user: creator, paypal_merchant_id: paypal_merchant_id)
        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
      end
    end

    context "when the PayPal OAuth grant belongs to another partner" do
      let(:creator) { create(:user) }
      let(:paypal_merchant_id) { "GSQ5PDPXZCWGW" }
      let(:oauth_integrations) do
        [{
          "integration_type" => "OAUTH_THIRD_PARTY",
          "integration_method" => "PAYPAL",
          "oauth_third_party" => [{ "partner_client_id" => "another-partner-client-id" }]
        }]
      end

      before do
        allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(
          "country" => "US",
          "primary_currency" => "USD",
          "primary_email_confirmed" => true,
          "payments_receivable" => true,
          "primary_email" => "seller@example.com",
          "oauth_integrations" => oauth_integrations
        )
      end

      it "leaves the account incomplete" do
        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
        expect(creator.merchant_accounts.charge_processor_verified.paypal).to be_empty
        expect(creator.reload.paypal_connect_account).to be_nil
      end

      it "accepts Gumroad's grant when it follows another partner's grant" do
        oauth_integrations.first["oauth_third_party"] << { "partner_client_id" => PAYPAL_PARTNER_CLIENT_ID }

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("You have successfully connected your PayPal account with Gumroad.")
        expect(creator.merchant_accounts.charge_processor_verified.paypal.count).to eq(1)
      end

      it "accepts Gumroad's grant when it is in a later integration" do
        oauth_integrations << {
          "integration_type" => "OAUTH_THIRD_PARTY",
          "integration_method" => "PAYPAL",
          "oauth_third_party" => [{ "partner_client_id" => PAYPAL_PARTNER_CLIENT_ID }]
        }

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("You have successfully connected your PayPal account with Gumroad.")
        expect(creator.merchant_accounts.charge_processor_verified.paypal.count).to eq(1)
      end

      it "treats a partial OAuth integration as incomplete" do
        oauth_integrations.first.delete("oauth_third_party")
        result = nil

        expect { result = subject.update_merchant_account(user: creator, paypal_merchant_id:) }.not_to raise_error
        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
      end

      it "treats malformed integration and grant entries as incomplete" do
        oauth_integrations.replace([nil, {
                                     "integration_type" => "OAUTH_THIRD_PARTY",
                                     "integration_method" => "PAYPAL",
                                     "oauth_third_party" => [nil]
                                   }])
        result = nil

        expect { result = subject.update_merchant_account(user: creator, paypal_merchant_id:) }.not_to raise_error
        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
      end

      it "rejects Gumroad's grant under the wrong integration type" do
        oauth_integrations.first["integration_type"] = "FIRST_PARTY"
        oauth_integrations.first["oauth_third_party"] = [{ "partner_client_id" => PAYPAL_PARTNER_CLIENT_ID }]

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
      end

      it "rejects Gumroad's grant under the wrong integration method" do
        oauth_integrations.first["integration_method"] = "BRAINTREE"
        oauth_integrations.first["oauth_third_party"] = [{ "partner_client_id" => PAYPAL_PARTNER_CLIENT_ID }]

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("Your PayPal account connect with Gumroad is incomplete because of missing permissions. Please try connecting again and grant the requested permissions.")
      end
    end

    describe "connecting a PayPal account whose email PayPal has permanently refused for payouts" do
      let(:creator) { create(:user) }
      let(:paypal_merchant_id) { "GSQ5PDPXZCWGW" }
      let(:refused_email) { "refused@example.com" }

      before do
        creator.mark_compliant!(author_name: "ContentModeration")
        allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
        create(:payment_completed, user: creator)
        allow_any_instance_of(MerchantAccount).to receive(:paypal_account_details).and_return(
          "country" => "US",
          "primary_currency" => "USD",
          "primary_email_confirmed" => true,
          "payments_receivable" => true,
          "primary_email" => refused_email,
          "oauth_integrations" => [{
            "integration_type" => "OAUTH_THIRD_PARTY",
            "integration_method" => "PAYPAL",
            "oauth_third_party" => [{ "partner_client_id" => PAYPAL_PARTNER_CLIENT_ID }]
          }]
        )
      end

      # Connect is a second door to the same payout address and the payout processor refuses by
      # address, so without this the seller is told the connection worked, sees it listed as
      # connected, and every payout goes on being blocked. gumroad-private#1478.
      it "refuses the connection and leaves no live merchant account behind" do
        create(:payment_failed, user: creator, payment_address: refused_email,
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("PayPal won't accept payouts to that account. Please connect a different PayPal account.")
        expect(creator.merchant_accounts.alive.paypal.count).to eq(0)
        expect(creator.merchant_accounts.charge_processor_verified.paypal.count).to eq(0)
      end

      # The guard has to be about the rejection, not about Connect. If it fired for any seller with
      # any failed payment the example above would pass for the wrong reason.
      it "connects normally when the rejection is a repairable currency one" do
        create(:payment_failed, user: creator, payment_address: refused_email,
                                failure_reason: "PAYPAL 14159", txn_id: nil, processor_fee_cents: nil)

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("You have successfully connected your PayPal account with Gumroad.")
        expect(creator.merchant_accounts.charge_processor_verified.paypal.count).to eq(1)
      end

      # A successful payout after the rejection means the account was repaired, and
      # terminal_failure_for_payout_email? already scopes to failures since the last completed
      # payout. Pinning it here stops a future widening of the guard from locking those sellers out.
      it "connects normally when a payout to that address has succeeded since the rejection" do
        create(:payment_failed, user: creator, payment_address: refused_email,
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil,
                                created_at: 2.days.ago)
        create(:payment_completed, user: creator, payment_address: refused_email, created_at: 1.day.ago)

        result = subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(result).to eq("You have successfully connected your PayPal account with Gumroad.")
        expect(creator.merchant_accounts.charge_processor_verified.paypal.count).to eq(1)
      end

      # Tearing down an already-live merchant account on a webhook would stop the seller taking
      # payments, which no rejection of a payout justifies.
      it "leaves an already-verified merchant account connected" do
        create(:payment_failed, user: creator, payment_address: refused_email,
                                failure_reason: "PAYPAL 3148", txn_id: nil, processor_fee_cents: nil)
        create(:merchant_account_paypal, charge_processor_merchant_id: paypal_merchant_id, user: creator,
                                         charge_processor_alive_at: 1.hour.ago, charge_processor_verified_at: 1.hour.ago)

        subject.update_merchant_account(user: creator, paypal_merchant_id:)

        expect(creator.merchant_accounts.alive.paypal.charge_processor_verified.count).to eq(1)
      end
    end

    it "marks all other paypal merchant accounts of the creator as deleted" do
      creator = create(:user)
      creator.mark_compliant!(author_name: "ContentModeration")
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(100_00)
      create(:payment_completed, user: creator)
      create(:merchant_account_paypal, user: creator)
      create(:merchant_account_paypal, user: creator)

      new_paypal_merchant_id = "GSQ5PDPXZCWGW"
      old_records =
        creator.merchant_accounts.alive.paypal.where.not(charge_processor_merchant_id: new_paypal_merchant_id)
      expect(old_records.count).to eq(2)

      subject.update_merchant_account(user: creator, paypal_merchant_id: new_paypal_merchant_id)

      expect(old_records.count).to eq(0)
      expect(creator.merchant_account("paypal").charge_processor_merchant_id).to eq(new_paypal_merchant_id)
    end
  end

  describe "#disconnect" do
    it "removes products from recommendable search results when PayPal was the seller's only payout method", :elasticsearch_wait_for_refresh do
      seller = create(:compliant_user, name: "PayPal seller", payment_address: nil)
      product = create(:product, user: seller, taxonomy: create(:taxonomy))
      create(:merchant_account, user: nil)
      create(:purchase, link: product, seller:, price_cents: product.price_cents)
      create(:merchant_account_paypal, user: seller, charge_processor_verified_at: Time.current)
      index_model_records(Link)

      recommendable_product_ids = -> {
        Link.search(Link.search_options(ids: [product.id], include_rated_as_adult: true)).records.map(&:id)
      }
      expect(product.reload.recommendable?).to eq(true)
      expect(recommendable_product_ids.call).to eq([product.id])

      RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs.clear
      expect do
        described_class.new.disconnect(user: seller)
      end.to change(RefreshMerchantAccountProductsRecommendationEligibilityJob.jobs, :size).by(1)
      RefreshMerchantAccountProductsRecommendationEligibilityJob.drain
      Link.__elasticsearch__.refresh_index!

      expect(product.reload.recommendable?).to eq(false)
      expect(EsClient.get(index: Link.index_name, id: product.id).dig("_source", "is_recommendable")).to eq(false)
      expect(recommendable_product_ids.call).to be_empty
    end
  end
end
