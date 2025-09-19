# frozen_string_literal: true

require "spec_helper"

describe StripeEventHandler, "guardian verification events" do
  let(:user) { create(:user) }
  let(:user_compliance_info) { create(:user_compliance_info, user: user) }
  let(:merchant_account) { create(:merchant_account, user: user, charge_processor_id: 'stripe') }

  before do
    user_compliance_info.update!(
      birthday: 17.years.ago,
      guardian_first_name: "John",
      guardian_last_name: "Doe",
      guardian_email: "guardian@example.com",
      guardian_phone: "555-1234",
      guardian_street_address: "123 Main St",
      guardian_city: "Anytown",
      guardian_state: "CA",
      guardian_zip_code: "12345",
      guardian_date_of_birth: 40.years.ago,
      guardian_stripe_tos_accepted: true,
      guardian_stripe_processing_tos_accepted: true
    )
  end

  describe "#handle_stripe_event" do
    context "with person.updated event for guardian" do
      let(:event_params) do
        {
          id: "evt_guardian_verification_123",
          type: "person.updated",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      it "calls StripeMerchantAccountManager.handle_stripe_event" do
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event)
          .with(instance_of(Stripe::Person))

        described_class.new(event_params).handle_stripe_event
      end

      it "processes the event successfully" do
        expect {
          described_class.new(event_params).handle_stripe_event
        }.not_to raise_error
      end
    end

    context "with person.created event for guardian" do
      let(:event_params) do
        {
          id: "evt_guardian_creation_123",
          type: "person.created",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "pending" }
            }
          }
        }
      end

      it "calls StripeMerchantAccountManager.handle_stripe_event" do
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event)
          .with(instance_of(Stripe::Person))

        described_class.new(event_params).handle_stripe_event
      end
    end

    context "with person.updated event for non-guardian" do
      let(:event_params) do
        {
          id: "evt_regular_person_123",
          type: "person.updated",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_regular_123",
              relationship: { representative: false, owner: true },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      it "calls StripeMerchantAccountManager.handle_stripe_event" do
        expect(StripeMerchantAccountManager).to receive(:handle_stripe_event)
          .with(instance_of(Stripe::Person))

        described_class.new(event_params).handle_stripe_event
      end
    end

    context "with unhandled event type" do
      let(:event_params) do
        {
          id: "evt_unhandled_123",
          type: "unhandled.event",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: { id: "obj_123" }
          }
        }
      end

      it "logs error for unhandled event" do
        expect(Rails.logger).to receive(:error).with(/Unhandled event unhandled\.event/)

        described_class.new(event_params).handle_stripe_event
      end

      it "does not call StripeMerchantAccountManager" do
        expect(StripeMerchantAccountManager).not_to receive(:handle_stripe_event)

        described_class.new(event_params).handle_stripe_event
      end
    end

    context "with error during processing" do
      let(:event_params) do
        {
          id: "evt_guardian_verification_123",
          type: "person.updated",
          account: merchant_account.charge_processor_merchant_id,
          data: {
            object: {
              id: "person_guardian_123",
              relationship: { representative: true, owner: false, title: "Legal Guardian" },
              verification: { status: "verified" }
            },
            previous_attributes: {
              verification: { status: "pending" }
            }
          }
        }
      end

      before do
        allow(StripeMerchantAccountManager).to receive(:handle_stripe_event)
          .and_raise(StandardError.new("Processing error"))
      end

      context "in staging environment" do
        before { allow(Rails.env).to receive(:staging?).and_return(true) }

        it "logs error and continues" do
          expect(Rails.logger).to receive(:error).with(/Error while handling event/)

          expect {
            described_class.new(event_params).handle_stripe_event
          }.not_to raise_error
        end
      end

      context "in non-staging environment" do
        before { allow(Rails.env).to receive(:staging?).and_return(false) }

        it "raises the error" do
          expect {
            described_class.new(event_params).handle_stripe_event
          }.to raise_error(StandardError, "Processing error")
        end
      end
    end
  end

  describe "event type handling" do
    it "handles person.* events" do
      expect(StripeEventHandler::ALL_HANDLED_EVENTS).to include("person.")
    end

    it "includes person events in handled events" do
      person_events = StripeEventHandler::ALL_HANDLED_EVENTS.select { |event| event.start_with?("person.") }
      expect(person_events).not_to be_empty
    end
  end
end
