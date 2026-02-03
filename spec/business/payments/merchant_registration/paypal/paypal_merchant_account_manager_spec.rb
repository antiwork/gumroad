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
          @merchant_account.user.mark_compliant!(author_name: "Iffy")
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
      creator.mark_compliant!(author_name: "Iffy")
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

    it "marks all other paypal merchant accounts of the creator as deleted" do
      creator = create(:user)
      creator.mark_compliant!(author_name: "Iffy")
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
end
