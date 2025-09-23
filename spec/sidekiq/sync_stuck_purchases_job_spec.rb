# frozen_string_literal: true

require "spec_helper"

describe SyncStuckPurchasesJob, :vcr do
  describe "#perform" do
    let(:product) { create(:product) }
    before do
      stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id)
    end

    it "does not sync any purchases if there are none in progress" do
      create(:failed_purchase, link: product, created_at: 12.hours.ago)
      create(:purchase, link: product, created_at: 24.hours.ago)

      expect_any_instance_of(Purchase).to_not receive(:sync_status_with_charge_processor)

      described_class.new.perform
    end

    it "does not sync any in progress purchases if they are outside of the query time range" do
      create(:purchase_in_progress, link: product, created_at: 4.days.ago)
      create(:purchase_in_progress, link: product, created_at: 2.hours.ago)

      expect_any_instance_of(Purchase).to_not receive(:sync_status_with_charge_processor)

      described_class.new.perform
    end

    it "does not sync an in progress purchases if it is an off session charge on an Indian card created less than 26 hours ago" do
      stuck_in_progress_purchase_that_would_succeed_if_synced = travel_to(Time.current - 12.hours) do
        purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable))
        purchase.process!
        purchase
      end

      allow_any_instance_of(Purchase).to receive(:is_an_off_session_charge_on_indian_card?).and_return(true)
      expect_any_instance_of(Purchase).to_not receive(:sync_status_with_charge_processor)
      expect(stuck_in_progress_purchase_that_would_succeed_if_synced.in_progress?).to eq(true)

      described_class.new.perform

      expect(stuck_in_progress_purchase_that_would_succeed_if_synced.reload.in_progress?).to eq(true)
    end

    it "syncs the in progress free purchase and does nothing if the new purchase state is successful and there are no subsequent successful purchases" do
      stuck_in_progress_free_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
        offer_code = create(:offer_code, products: [product], amount_cents: 100)
        purchase = create(:free_purchase, link: product, purchase_state: "in_progress", offer_code:)
        purchase.process!
        purchase
      end

      expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.in_progress?).to be(true)

      described_class.new.perform

      expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
      expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.refunded?).to eq(false)
    end

    it "syncs the in progress purchase and does nothing if the new purchase state is successful and there are no subsequent successful purchases" do
      stuck_in_progress_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
        purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable))
        purchase.process!
        purchase
      end

      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.in_progress?).to eq(true)

      described_class.new.perform

      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.refunded?).to eq(false)
    end

    it "syncs the in progress which is an off session charge on an Indian card created more than 26 hours ago and does nothing if the new purchase state is successful and there are no subsequent successful purchases" do
      stuck_in_progress_purchase_that_will_succeed_when_synced = travel_to(Time.current - 27.hours) do
        purchase = create(:purchase, link: product, purchase_state: "in_progress", chargeable: create(:chargeable))
        purchase.process!
        purchase
      end

      allow_any_instance_of(Purchase).to receive(:is_an_off_session_charge_on_indian_card?).and_return(true)
      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.in_progress?).to eq(true)

      described_class.new.perform

      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
      expect(stuck_in_progress_purchase_that_will_succeed_when_synced.refunded?).to eq(false)
    end

    context "when there is a subsequent successful purchase" do
      let!(:successful_purchase) { create(:purchase, link: product) }

      it "syncs the in progress purchase and does nothing if the new purchase state is failed" do
        stuck_in_progress_purchase_that_will_fail_when_synced = travel_to(Time.current - 12.hours) do
          purchase = create(:purchase, link: product, email: successful_purchase.email, purchase_state: "in_progress", chargeable: create(:chargeable_success_charge_decline))
          purchase.process!
          purchase.stripe_transaction_id = nil
          purchase.save!
          purchase
        end

        expect(stuck_in_progress_purchase_that_will_fail_when_synced.in_progress?).to eq(true)
        expect_any_instance_of(Purchase).to_not receive(:refund_and_save!)

        described_class.new.perform

        expect(stuck_in_progress_purchase_that_will_fail_when_synced.reload.failed?).to eq(true)
      end

      it "syncs the in progress purchase and then refunds it if the new purchase state is successful" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)

        stuck_in_progress_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
          purchase = create(:purchase, link: product, email: successful_purchase.email, purchase_state: "in_progress", chargeable: create(:chargeable))
          purchase.process!
          purchase
        end

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.in_progress?).to eq(true)

        described_class.new.perform

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.refunded?).to eq(true)
      end

      it "syncs the in progress free purchase and then does not refund it because it is free if the new purchase state is successful" do
        stuck_in_progress_free_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
          offer_code = create(:offer_code, products: [product], amount_cents: 100)
          purchase = create(:free_purchase, link: product, email: successful_purchase.email, purchase_state: "in_progress", offer_code:)
          purchase.process!
          purchase
        end

        expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.in_progress?).to be(true)

        described_class.new.perform

        expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
        expect(stuck_in_progress_free_purchase_that_will_succeed_when_synced.refunded?).to eq(false)
      end
    end

    context "when there is a subsequent successful purchase for a variant of the product" do
      let(:product_with_digital_versions) { create(:product_with_digital_versions) }
      let!(:successful_purchase_of_variant) { create(:purchase, link: product_with_digital_versions, variant_attributes: [product_with_digital_versions.variants.last]) }

      it "syncs the in progress purchase and does nothing if the new purchase state is failed" do
        stuck_in_progress_purchase_that_will_fail_when_synced = travel_to(Time.current - 12.hours) do
          purchase = create(:purchase, link: product_with_digital_versions, email: successful_purchase_of_variant.email, purchase_state: "in_progress",  variant_attributes: [product_with_digital_versions.variants.last], chargeable: create(:chargeable_success_charge_decline))
          purchase.process!
          purchase.stripe_transaction_id = nil
          purchase.save!
          purchase
        end

        expect(stuck_in_progress_purchase_that_will_fail_when_synced.in_progress?).to eq(true)

        described_class.new.perform

        expect(stuck_in_progress_purchase_that_will_fail_when_synced.reload.failed?).to eq(true)
      end

      it "syncs the in progress purchase and then refunds it if the new purchase state is successful for the same variant of the product" do
        allow_any_instance_of(User).to receive(:unpaid_balance_cents).and_return(100_00)

        stuck_in_progress_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
          purchase = create(:purchase, link: product_with_digital_versions, email: successful_purchase_of_variant.email, purchase_state: "in_progress", variant_attributes: [product_with_digital_versions.variants.last], chargeable: create(:chargeable))
          purchase.process!
          purchase
        end

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.in_progress?).to eq(true)

        described_class.new.perform

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.refunded?).to eq(true)
      end

      it "syncs the in progress purchase and then does NOT refund it if the new purchase state is successful for a different variant of the product" do
        stuck_in_progress_purchase_that_will_succeed_when_synced = travel_to(Time.current - 12.hours) do
          purchase = create(:purchase, link: product_with_digital_versions, email: successful_purchase_of_variant.email, purchase_state: "in_progress", variant_attributes: [product_with_digital_versions.variants.first], chargeable: create(:chargeable))
          purchase.process!
          purchase
        end

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.in_progress?).to eq(true)
        expect_any_instance_of(Purchase).to_not receive(:refund_and_save!)

        described_class.new.perform

        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.reload.successful?).to eq(true)
        expect(stuck_in_progress_purchase_that_will_succeed_when_synced.refunded?).to eq(false)
      end
    end
  end
end
