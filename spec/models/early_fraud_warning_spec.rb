# frozen_string_literal: true

require "spec_helper"

describe EarlyFraudWarning do
  describe "validations" do
    describe "for Purchase" do
      let(:purchase_efw) { create(:early_fraud_warning) }

      it "validates uniqueness of processor_id" do
        new_record = build(:early_fraud_warning, processor_id: purchase_efw.processor_id)
        expect(new_record).not_to be_valid
        expect(new_record.errors.messages).to eq(
          processor_id: ["has already been taken"]
        )
      end

      it "validates uniqueness of purchase" do
        new_record = build(:early_fraud_warning, processor_id: "issfr_new", purchase: purchase_efw.purchase)
        expect(new_record).not_to be_valid
        expect(new_record.errors.messages).to eq(
          purchase: ["has already been taken"]
        )
      end
    end

    describe "for Charge" do
      let(:charge_efw) { create(:early_fraud_warning, charge: create(:charge), purchase: nil) }

      context "when both a purchase and charge are present" do
        it "is not valid" do
          charge_efw.purchase = create(:purchase)
          expect(charge_efw).not_to be_valid
          expect(charge_efw.errors.messages).to eq(
            base: ["Only a purchase or a charge is allowed."]
          )
        end
      end

      it "validates uniqueness of charge" do
        new_record = build(:early_fraud_warning, processor_id: "issfr_new", charge: charge_efw.charge, purchase: nil)
        expect(new_record).not_to be_valid
        expect(new_record.errors.messages).to eq(
          charge: ["has already been taken"]
        )
      end
    end
  end

  describe "#update_from_stripe!" do
    let(:early_fraud_warning) { create(:early_fraud_warning) }

    it "calls the service" do
      expect(EarlyFraudWarning::UpdateService).to receive(:new).with(early_fraud_warning).and_return(double(perform!: true))
      early_fraud_warning.update_from_stripe!
    end

    context "when EarlyFraudWarning::UpdateService::AlreadyResolvedError is raised" do
      it "ignores the error" do
        expect(EarlyFraudWarning::UpdateService).to receive(:new).with(early_fraud_warning)
          .and_raise(EarlyFraudWarning::UpdateService::AlreadyResolvedError)
        expect { early_fraud_warning.update_from_stripe! }.not_to raise_error
      end
    end
  end

  describe "#chargeable_refundable_for_fraud?" do
    RSpec.shared_examples "for a Chargeable" do
      context "when eligible" do
        it "returns true" do
          expect(early_fraud_warning.chargeable_refundable_for_fraud?).to eq(true)
        end
      end

      context "when the purchase was created before the dispute window" do
        before do
          chargeable.update!(created_at: (EarlyFraudWarning::ELIGIBLE_DISPUTE_WINDOW_DURATION + 1).days.ago)
          expect_any_instance_of(chargeable.class).not_to receive(:buyer_blocked?)
        end

        it "returns false" do
          expect(early_fraud_warning.chargeable_refundable_for_fraud?).to eq(false)
        end
      end
    end

    describe "for a Purchase" do
      let(:purchase) { create(:purchase, stripe_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL") }
      let!(:early_fraud_warning) { create(:early_fraud_warning, purchase:) }
      let(:chargeable) { purchase }

      include_examples "for a Chargeable"
    end

    describe "for a Charge" do
      let(:charge) do
        create(
          :charge,
          processor_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL",
          purchases: [create(:purchase, stripe_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL")]
        )
      end
      let!(:early_fraud_warning) { create(:early_fraud_warning, charge:, purchase: nil) }
      let(:chargeable) { charge }

      include_examples "for a Chargeable"
    end
  end

  describe "#purchase_for_subscription_contactable?" do
    let!(:early_fraud_warning) do
      create(
        :early_fraud_warning,
        purchase:,
        fraud_type: EarlyFraudWarning::FRAUD_TYPE_UNAUTHORIZED_USE_OF_CARD,
        charge_risk_level: EarlyFraudWarning::CHARGE_RISK_LEVEL_NORMAL
      )
    end

    context "when the purchase is not a subscription" do
      let(:purchase) { create(:purchase, stripe_transaction_id: "ch_2O8n7J9e1RjUNIyY1rs9MIRL") }

      it "returns false" do
        expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(false)
      end
    end

    context "when the purchase is for a subscription" do
      let(:purchase) { create(:membership_purchase) }

      context "when the purchase doesn't have a CustomerEmailInfo record" do
        it "returns false" do
          expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(false)
        end
      end

      context "when the purchase has a CustomerEmailInfo record" do
        context "when the CustomerEmailInfo has an eligible state" do
          before do
            create(:customer_email_info_sent, purchase:)
          end

          it "returns true" do
            expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(true)
          end

          context "when the risk level is not eligible" do
            before do
              early_fraud_warning.update!(charge_risk_level: EarlyFraudWarning::CHARGE_RISK_LEVEL_ELEVATED)
            end

            it "returns false" do
              expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(false)
            end
          end

          context "when the fraud_type is not unauthorized use of card" do
            before do
              early_fraud_warning.update!(fraud_type: EarlyFraudWarning::FRAUD_TYPE_MISC)
            end

            it "returns false" do
              expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(false)
            end
          end
        end

        context "when the CustomerEmailInfo doesn't have an eligible state" do
          before do
            create(:customer_email_info, purchase:) # created state
          end

          it "returns false" do
            expect(early_fraud_warning.purchase_for_subscription_contactable?).to eq(false)
          end
        end
      end
    end
  end

  describe "#associated_early_fraud_warning_ids_for_subscription_contacted" do
    let(:purchase) { create(:membership_purchase) }
    let(:subscription) { purchase.subscription }

    describe "for a Purchase" do
      let(:early_fraud_warning) { create(:early_fraud_warning, purchase:) }

      context "without associated purchases" do
        it "returns an empty array" do
          expect(
            early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
          ).to eq([])
        end
      end

      context "with associated purchases" do
        let!(:other_purchase) { create(:purchase, subscription:) }
        let!(:other_early_fraud_warning) do
          create(:early_fraud_warning, purchase: other_purchase, processor_id: "issfr_other")
        end

        context "when the associated purchase early fraud warning is not resolved" do
          it "returns an empty array" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([])
          end
        end

        context "when the associated purchase early fraud warning is resolved as ignored" do
          before do
            other_early_fraud_warning.update!(resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED)
          end

          it "returns an empty array" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([])
          end
        end

        context "when the associated purchase early fraud warning is resolved as contacted" do
          before do
            other_early_fraud_warning.update!(
              resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_CUSTOMER_CONTACTED
            )
          end

          it "returns the associated purchase early fraud warning ids" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([other_early_fraud_warning.id])
          end
        end
      end
    end

    describe "for a Charge" do
      let(:charge) { create(:charge, purchases: [purchase]) }
      let(:early_fraud_warning) { create(:early_fraud_warning, charge:, purchase: nil) }

      context "without associated purchases" do
        it "returns an empty array" do
          expect(
            early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
          ).to eq([])
        end
      end

      context "with associated purchases" do
        let!(:other_purchase) { create(:purchase, subscription:) }
        let!(:other_early_fraud_warning) do
          create(:early_fraud_warning, purchase: other_purchase, processor_id: "issfr_other")
        end

        context "when the associated purchase early fraud warning is not resolved" do
          it "returns an empty array" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([])
          end
        end

        context "when the associated purchase early fraud warning is resolved as ignored" do
          before do
            other_early_fraud_warning.update!(resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_IGNORED)
          end

          it "returns an empty array" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([])
          end
        end

        context "when the associated purchase early fraud warning is resolved as contacted" do
          before do
            other_early_fraud_warning.update!(
              resolution: EarlyFraudWarning::RESOLUTION_RESOLVED_CUSTOMER_CONTACTED
            )
          end

          it "returns the associated purchase early fraud warning ids" do
            expect(
              early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
            ).to eq([other_early_fraud_warning.id])
          end

          context "when the associated purchase early fraud warning is associated with a charge" do
            let(:other_charge) { create(:charge, purchases: [other_purchase]) }
            let!(:other_early_fraud_warning) do
              create(:early_fraud_warning, purchase: nil, charge: other_charge, processor_id: "issfr_other")
            end

            it "returns the associated purchase early fraud warning ids" do
              expect(
                early_fraud_warning.associated_early_fraud_warning_ids_for_subscription_contacted
              ).to eq([other_early_fraud_warning.id])
            end
          end
        end
      end
    end
  end

  describe "#purchase_for_subscription" do
    describe "for a Purchase" do
      let(:purchase) { create(:purchase) }
      let(:early_fraud_warning) { create(:early_fraud_warning, purchase:) }

      context "when the purchase is not for membership" do
        it "returns nil" do
          expect(early_fraud_warning.purchase_for_subscription).to be_nil
        end
      end

      context "when the purchase is for membership" do
        let(:purchase) { create(:membership_purchase) }

        it "returns the purchase" do
          expect(early_fraud_warning.purchase_for_subscription).to eq(purchase)
        end
      end
    end

    describe "for a Charge" do
      let(:purchase) { create(:purchase) }
      let(:charge) { create(:charge, purchases: [purchase]) }
      let(:early_fraud_warning) { create(:early_fraud_warning, charge:, purchase: nil) }

      context "when the charge has no membership purchases" do
        it "returns nil" do
          expect(early_fraud_warning.purchase_for_subscription).to be_nil
        end
      end

      context "when the charge has a membership purchase" do
        let(:membership_purchase) { create(:membership_purchase) }
        before do
          charge.purchases << membership_purchase
        end

        it "returns the purchase" do
          expect(early_fraud_warning.purchase_for_subscription).to eq(membership_purchase)
        end
      end
    end
  end

  describe "#chargeable" do
    context "with a Purchase" do
      let(:purchase) { create(:purchase) }
      let(:early_fraud_warning) { create(:early_fraud_warning, purchase:) }

      it "returns the purchase" do
        expect(early_fraud_warning.chargeable).to eq(purchase)
      end
    end

    context "with a Charge" do
      let(:charge) { create(:charge) }
      let(:early_fraud_warning) { create(:early_fraud_warning, charge:, purchase: nil) }

      it "returns the charge" do
        expect(early_fraud_warning.chargeable).to eq(charge)
      end
    end
  end

  describe "#receipt_email_info" do
    let(:early_fraud_warning) { create(:early_fraud_warning) }

    context "when there are no purchase email infos" do
      it "returns nil" do
        expect(early_fraud_warning.send(:receipt_email_info)).to be_nil
      end
    end

    context "when there are purchase email infos" do
      let(:purchase) { early_fraud_warning.purchase }
      let!(:email_info_old) { create(:customer_email_info, purchase:, email_name: "receipt", state: "sent") }
      let!(:email_info) { create(:customer_email_info, purchase:, email_name: "receipt", state: "bounced") }

      it "returns the last receipt email info" do
        expect(early_fraud_warning.send(:receipt_email_info)).to eq(email_info)
      end
    end
  end
end
