# frozen_string_literal: true

require "spec_helper"

describe SubmitGuardianToStripeWorker do
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

  describe "#perform" do
    context "when user is under 18 and has guardian information" do
      context "when no existing guardian person exists" do
        before do
          allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [] })
        end

        it "creates guardian person in Stripe" do
          expect(Stripe::Account).to receive(:create_person)
            .with(merchant_account.charge_processor_merchant_id, hash_including(
              first_name: "John",
              last_name: "Doe",
              email: "guardian@example.com"
            ))

          described_class.new.perform(user.id)
        end

        it "logs successful creation" do
          allow(Stripe::Account).to receive(:create_person)

          expect(Rails.logger).to receive(:info).with("Created guardian person for user #{user.id} in Stripe")

          described_class.new.perform(user.id)
        end
      end

      context "when existing guardian person exists" do
        let(:existing_person) do
          {
            "id" => "person_123",
            "relationship" => { "representative" => true, "owner" => false }
          }
        end

        before do
          allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [existing_person] })
        end

        it "updates existing guardian person" do
          expect(Stripe::Account).to receive(:update_person)
            .with(merchant_account.charge_processor_merchant_id, "person_123", hash_including(
              first_name: "John",
              last_name: "Doe"
            ))

          described_class.new.perform(user.id)
        end

        it "logs successful update" do
          allow(Stripe::Account).to receive(:update_person)

          expect(Rails.logger).to receive(:info).with("Updated guardian person for user #{user.id} in Stripe")

          described_class.new.perform(user.id)
        end
      end
    end

    context "when user is 18 or older" do
      before { user.update!(birthday: 19.years.ago) }

      it "does not submit to Stripe" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(user.id)
      end
    end

    context "when user has no merchant account" do
      before { merchant_account.destroy! }

      it "does not submit to Stripe" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(user.id)
      end
    end

    context "when user has no compliance info" do
      before { user_compliance_info.destroy! }

      it "does not submit to Stripe" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(user.id)
      end
    end

    context "when user doesn't exist" do
      it "returns early without error" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(99999)
      end
    end

    context "when Stripe submission fails" do
      before do
        allow(Stripe::Account).to receive(:list_persons).and_return({ "data" => [] })
        allow(Stripe::Account).to receive(:create_person).and_raise(Stripe::StripeError.new("API Error"))
      end

      it "notifies Bugsnag and logs error" do
        expect(Bugsnag).to receive(:notify).with(
          "Failed to submit guardian info to Stripe for user #{user.id}: API Error"
        )
        expect(Rails.logger).to receive(:error).with(
          "Failed to submit guardian info to Stripe for user #{user.id}: API Error"
        )

        expect {
          described_class.new.perform(user.id)
        }.to raise_error(Stripe::StripeError)
      end
    end

    context "when user has no alive merchant account" do
      before do
        merchant_account.update!(charge_processor_alive_at: nil)
      end

      it "does not submit to Stripe" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(user.id)
      end
    end

    context "when user has deleted merchant account" do
      before do
        merchant_account.update!(charge_processor_deleted_at: Time.current)
      end

      it "does not submit to Stripe" do
        expect(Stripe::Account).not_to receive(:create_person)
        expect(Stripe::Account).not_to receive(:update_person)

        described_class.new.perform(user.id)
      end
    end
  end

  describe "Sidekiq configuration" do
    it "includes Sidekiq::Worker" do
      expect(described_class.ancestors).to include(Sidekiq::Worker)
    end

    it "has perform method" do
      expect(described_class.instance_methods).to include(:perform)
    end
  end
end
