# frozen_string_literal: true

require "test_helper"

class ServiceChargeTest < ActiveSupport::TestCase
  self.described_class = ServiceCharge
  self.rspec_metadata = { vcr: true }



  context_ ServiceCharge, :vcr do
  context_ "scopes" do
  context_ "successful" do
        before do
          @successful_service_charge = create(:service_charge, state: "successful")
          @failed_service_charge = create(:service_charge, state: "failed")
        end

  test "returns successful service_charges" do
          expect(ServiceCharge.successful).to include @successful_service_charge
        end

  test "does not return failed service_charges" do
          expect(ServiceCharge.successful).not_to include @failed_service_charge
        end
      end

  context_ "failed" do
        before do
          @successful_service_charge = create(:service_charge, state: "successful")
          @failed_service_charge = create(:service_charge, state: "failed")
        end

  test "does not returns successful service_charges" do
          expect(ServiceCharge.failed).not_to include @successful_service_charge
        end

  test "does return failed service_charges" do
          expect(ServiceCharge.failed).to include @failed_service_charge
        end
      end

  context_ "refunded" do
        before do
          @refunded_service_charge = create(:service_charge, charge_processor_refunded: true)
          @non_refunded_service_charge = create(:service_charge)
        end

  test "returns refunded service_charges" do
          expect(ServiceCharge.refunded).to include @refunded_service_charge
        end

  test "does not return non-refunded service_charges" do
          expect(ServiceCharge.refunded).not_to include @non_refunded_service_charge
        end
      end

  context_ "not_refunded" do
        before do
          @refunded_service_charge = create(:service_charge, charge_processor_refunded: true)
          @non_refunded_service_charge = create(:service_charge)
        end

  test "returns non-refunded service_charges" do
          expect(ServiceCharge.not_refunded).to include @non_refunded_service_charge
        end

  test "does not return refunded service_charges" do
          expect(ServiceCharge.not_refunded).not_to include @refunded_service_charge
        end
      end

  context_ "not_chargedback" do
        before do
          @chargebacked_service_charge = create(:service_charge, chargeback_date: Date.yesterday)
          @reversed_chargebacked_service_charge = create(:service_charge, chargeback_date: Date.yesterday, chargeback_reversed: true)
          @non_chargebacked_service_charge = create(:service_charge)
        end

  test "does not return chargebacked service_charge" do
          expect(ServiceCharge.not_chargedback).not_to include @chargebacked_service_charge
          expect(ServiceCharge.not_chargedback).not_to include @reversed_chargebacked_service_charge
        end

  test "returns non-chargebacked service_charge" do
          expect(ServiceCharge.not_chargedback).to include @non_chargebacked_service_charge
          expect(ServiceCharge.not_chargedback).not_to include @reversed_chargebacked_service_charge
        end
      end
    end


  context_ "#mark_successful" do
  test "marks the service_charge as successful" do
        travel_to(Time.current) do
          service_charge = create(:service_charge, state: "in_progress")
          service_charge.mark_successful
          expect(service_charge.state).to eq("successful")
          expect(service_charge.succeeded_at.to_s).to eq(Time.current.to_s)
        end
      end
    end

  context_ "mark_failed" do
  test "marks the service_charge as failed" do
        service_charge = create(:service_charge, state: "in_progress")
        service_charge.mark_failed
        expect(service_charge.state).to eq("failed")
      end
    end

  context_ "email" do
  test "gets email from user" do
        user = create(:user)
        service_charge = create(:service_charge, user:)
        expect(service_charge.email).to eq user.email
      end
    end

  context_ "as_json method" do
      before do
        @user = create(:user)
        @service_charge = create(:service_charge, chargeback_date: 1.minute.ago, user: @user)
      end

  test "has the right keys" do
        %i[charge_cents formatted_charge timestamp user_id chargedback].each do |key|
          expect(@service_charge.as_json.key?(key)).to be(true)
        end
      end
    end

  context_ "#discount_amount" do
      before do
        @user = create(:user)
        @black_recurring_service = create(:black_recurring_service, user: @user)
        @service_charge = create(:free_service_charge, user: @user, recurring_service: @black_recurring_service, discount_code: DiscountCode::INVITE_CREDIT_DISCOUNT_CODE)
      end

  test "returns the right amount for invite discount" do
        expect(@service_charge.discount_amount).to eq("$10")
      end
    end

  context_ "#upload_invoice_pdf" do
      before(:each) do
        @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/service_charge-invoice-spec-#{SecureRandom.hex(18)}")

        s3_bucket_double = double
        allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).with(INVOICES_S3_BUCKET).and_return(s3_bucket_double)

        expect(s3_bucket_double).to receive_message_chain(:object).and_return(@s3_object)
      end

  test "writes the passed file to S3 and returns the S3 object" do
        service_charge = create(:service_charge)
        file = File.open(Rails.root.join("spec", "support", "fixtures", "smaller.png"))

        result = service_charge.upload_invoice_pdf(file)
        expect(result).to be(@s3_object)
        expect(result.content_length).to eq(file.size)
      end
    end
  end
end
