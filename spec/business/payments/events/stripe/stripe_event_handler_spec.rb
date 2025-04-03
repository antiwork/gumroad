# frozen_string_literal: true

describe StripeEventHandler do
  let(:event_id) { "evt_eventid" }

  describe "error handling", :vcr do
    context "when staging environment" do
      before do
        allow(Rails.env).to receive(:staging?).and_return(true)
      end

      it "silences errors" do
        expect { StripeEventHandler.new(id: "invalid-event-id").handle_stripe_event }.not_to raise_error
      end
    end

    context "when not staging environment" do
      before do
        allow(Rails.env).to receive(:staging?).and_return(false)
      end

      it "does not silence errors" do
        expect { StripeEventHandler.new(id: "invalid-event-id", type: "charge.succeeded").handle_stripe_event }.to raise_error(NoMethodError)
      end
    end
  end

  describe "an event on gumroad's account" do
    describe "a charge event" do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "charge.succeeded",
          "data" => {
            "object" => {
              "object" => "charge"
            }
          }
        }
      end

      it "sends the event to StripeChargeProcessor" do
        expect(StripeChargeProcessor).to receive(:handle_stripe_event).with(parsed(stripe_event))
        described_class.new(stripe_event).handle_stripe_event
      end
    end

    describe "a payment intent failed event" do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "payment_intent.payment_failed",
          "data" => {
            "object" => {
              "object" => "payment_intent"
            }
          }
        }
      end

      it "sends the event to StripeChargeProcessor" do
        expect(StripeChargeProcessor).to receive(:handle_stripe_event).with(parsed(stripe_event))
        described_class.new(stripe_event).handle_stripe_event
      end
    end

    describe "a capital loan event" do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1668996442",
          "type" => "capital.financing_transaction.created",
          "data" => {
            "object" => {
              "object" => "capital.financing_transaction"
            }
          }
        }
      end

      it "sends the event to StripeChargeProcessor" do
        expect(StripeChargeProcessor).to receive(:handle_stripe_event).with(parsed(stripe_event))
        described_class.new(stripe_event).handle_stripe_event
      end
    end

    describe "an account event" do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "account.updated",
          "data" => {
            "object" => {
              "object" => "account"
            }
          }
        }
      end

      it "does not send the event to StripeMerchantAccountManager" do
        expect(StripeMerchantAccountManager).not_to receive(:handle_stripe_event)
        described_class.new(stripe_event).handle_stripe_event
      end
    end

    describe "an ignored event" do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "invoice.created",
          "data" => {
            "object" => {
              "object" => "invoice"
            }
          }
        }
      end

      it "does not send the event to StripeChargeProcessor" do
        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).not_to receive(:handle_stripe_event)
        described_class.new(stripe_event).handle_stripe_event
      end

      it "does not retrieve event from stripe" do
        expect(Stripe::Event).to_not receive(:retrieve)
        described_class.new(stripe_event).handle_stripe_event
      end
    end
  end

  describe "an event on a connected account" do
    describe "an account event", :vcr do
      before do
        @user = create(:user)
        @merchant_account = create(:merchant_account_stripe, user: @user)
        @stripe_event = {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "account.updated",
          "account" => @merchant_account.charge_processor_merchant_id,
          "user_id" => @merchant_account.charge_processor_merchant_id,
          "default_currency" => "usd",
          "country" => "USA",
          "data" => {
            "object" => {
              "object" => "account",
              "default_currency" => "usd",
              "country" => "USA",
              "id" => @merchant_account.charge_processor_merchant_id
            }
          }
        }
        @merchant_account.charge_processor_merchant_id
      end

      it "sends the event to StripeMerchantAccountManager" do
        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event).and_call_original
        described_class.new(@stripe_event).handle_stripe_event
      end

      it "sends the event to StripeMerchantAccountManager when event has an account field" do
        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event).and_call_original
        described_class.new(@stripe_event).handle_stripe_event
      end

      it "updates currency and country for user merchant account" do
        @merchant_account.country = "UK"
        @merchant_account.currency = "gbp"
        @merchant_account.save!

        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event).and_call_original
        described_class.new(@stripe_event).handle_stripe_event

        @merchant_account.reload
        expect(@merchant_account.currency).to eq("usd")
        expect(@merchant_account.country).to eq("USA")
      end
    end

    describe "a payout event", :vcr do
      let(:stripe_event) do
        {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "payout.paid",
          "account" => "acct_1234",
          "user_id" => "acct_1234",
          "data" => {
            "object" => {
              "object" => "transfer",
              "type" => "bank_account",
              "id" => "tr_1234"
            }
          }
        }
      end

      it "sends the event to StripePayoutProcessor" do
        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).not_to receive(:handle_stripe_event)
        expect(StripePayoutProcessor).to receive(:handle_stripe_event).with(parsed(stripe_event), stripe_connect_account_id: "acct_1234")
        described_class.new(stripe_event).handle_stripe_event
      end
    end

    describe "account deauthorized", :vcr do
      before do
        @user = create(:user)
        @product = create(:product, user: @user)
        @merchant_account = create(:merchant_account_stripe, user: @user)
        @stripe_event = {
          "id" => event_id,
          "created" => "1406748559", # "2014-07-30T19:29:19+00:00"
          "type" => "account.updated",
          "account" => @merchant_account.charge_processor_merchant_id,
          "user_id" => @merchant_account.charge_processor_merchant_id,
          "data" => {
            "object" => {
              "object" => "account",
              "id" => @merchant_account.charge_processor_merchant_id
            }
          }
        }

        allow(Stripe::Account).to receive(:list_persons).and_raise(Stripe::APIError, "Application access may have been revoked.")
      end

      it "rescues Stripe::APIError exception" do
        expect { described_class.new(@stripe_event).handle_stripe_event }.not_to raise_error
      end

      it "deauthorizes the merchant account" do
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event_account_deauthorized).and_call_original
        described_class.new(@stripe_event).handle_stripe_event

        @merchant_account.reload
        expect(@merchant_account.meta).to eq(nil)
        expect(@merchant_account.charge_processor_merchant_id).to eq(@stripe_event[:account])
        expect(@merchant_account.deleted_at).not_to eq(nil)
        expect(@merchant_account.charge_processor_deleted_at).not_to eq(nil)
        expect(@product.alive?).to eq(true)
      end

      context "merchant_migration enabled" do
        before do
          Feature.activate_user(:merchant_migration, @user)
        end

        after do
          Feature.deactivate_user(:merchant_migration, @user)
        end

        it "does not unpublish the products for user" do
          expect(StripeMerchantAccountManager).to receive(:handle_stripe_event_account_deauthorized).and_call_original
          described_class.new(@stripe_event).handle_stripe_event
          @product.reload
          expect(@product.alive?).to eq(true)
        end
      end
    end

    describe "a capability event", :vcr do
      before do
        @user = create(:user)
        @merchant_account = create(:merchant_account_stripe, user: @user)
        @stripe_event = {
          "id" => event_id,
          "created" => "1406748559",
          "type" => "capability.updated",
          "account" => @merchant_account.charge_processor_merchant_id,
          "user_id" => @merchant_account.charge_processor_merchant_id,
          "data" => {
            "object" => {
              "object" => "capability",
              "id" => "transfers",
              "account" => @merchant_account.charge_processor_merchant_id,
              "requirements" => {
                "currently_due" => ["individual.verification.document"],
                "eventually_due" => ["individual.verification.document"],
                "past_due" => ["individual.verification.document"]
              }
            },
            "account" => {
              "id" => @merchant_account.charge_processor_merchant_id,
              "object" => "account",
              "charges_enabled" => true,
              "payouts_enabled" => true,
              "requirements" => {
                "currently_due" => [],
                "eventually_due" => [],
                "past_due" => []
              },
              "future_requirements" => {
                "currently_due" => [],
                "eventually_due" => [],
                "past_due" => []
              }
            },
            "previous_attributes" => {}
          }
        }
      end

      it "sends the event to StripeMerchantAccountManager" do
        expect(StripeChargeProcessor).not_to receive(:handle_stripe_event)
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event).and_call_original
        described_class.new(@stripe_event).handle_stripe_event
      end
    end
  end

  private
    def parsed(event)
      Stripe::Util.convert_to_stripe_object(event, {})
    end
end
