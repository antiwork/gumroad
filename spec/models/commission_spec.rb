# frozen_string_literal: true

describe Commission, :vcr do
  describe "validations" do
    it "validates inclusion of status in STATUSES" do
      commission = build(:commission, status: "invalid_status")
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Status is not included in the list")
      commission.status = nil
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Status is not included in the list")
    end

    it "validates presence of deposit_purchase" do
      commission = build(:commission, deposit_purchase: nil)
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Deposit purchase must exist")
    end

    it "validates that deposit_purchase and completion_purchase are different" do
      purchase = create(:purchase)
      commission = build(:commission, deposit_purchase: purchase, completion_purchase: purchase)
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Deposit purchase and completion purchase must be different purchases")
    end

    it "validates that deposit_purchase and completion_purchase belong to the same commission" do
      commission = build(:commission, deposit_purchase: create(:purchase, link: create(:product)), completion_purchase: create(:purchase, link: create(:product)))
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Deposit purchase and completion purchase must belong to the same commission product")
    end

    it "validates that the purchased product is a commission" do
      product = create(:product, native_type: Link::NATIVE_TYPE_DIGITAL)
      commission = build(:commission, deposit_purchase: create(:purchase, link: product), completion_purchase: create(:purchase, link: product))
      expect(commission).to be_invalid
      expect(commission.errors.full_messages).to include("Purchased product must be a commission")
    end
  end

  describe "#create_completion_purchase!" do
    context "when status is already completed" do
      let!(:commission) { create(:commission, status: Commission::STATUS_COMPLETED) }

      it "does not create a completion purchase" do
        expect { commission.create_completion_purchase! }.not_to change { Purchase.count }
      end
    end

    context "when status is not completed" do
      let(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }
      let(:deposit_purchase) { commission.deposit_purchase }
      let(:product) { deposit_purchase.link }

      before do
        deposit_purchase.update!(zip_code: "10001")
        deposit_purchase.update!(displayed_price_cents: 100)
        deposit_purchase.create_tip!(value_cents: 20)
        deposit_purchase.variant_attributes << create(:variant, name: "Deluxe")
      end

      it "creates a completion purchase with correct attributes, processes it, and updates status" do
        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

        completion_purchase = commission.reload.completion_purchase
        expect(completion_purchase.perceived_price_cents).to eq((deposit_purchase.price_cents / Commission::COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.price_cents)
        expect(completion_purchase.link).to eq(deposit_purchase.link)
        expect(completion_purchase.purchaser).to eq(deposit_purchase.purchaser)
        expect(completion_purchase.credit_card_id).to eq(deposit_purchase.credit_card_id)
        expect(completion_purchase.email).to eq(deposit_purchase.email)
        expect(completion_purchase.full_name).to eq(deposit_purchase.full_name)
        expect(completion_purchase.street_address).to eq(deposit_purchase.street_address)
        expect(completion_purchase.country).to eq(deposit_purchase.country)
        expect(completion_purchase.zip_code).to eq(deposit_purchase.zip_code)
        expect(completion_purchase.city).to eq(deposit_purchase.city)
        expect(completion_purchase.ip_address).to eq(deposit_purchase.ip_address)
        expect(completion_purchase.ip_state).to eq(deposit_purchase.ip_state)
        expect(completion_purchase.ip_country).to eq(deposit_purchase.ip_country)
        expect(completion_purchase.browser_guid).to eq(deposit_purchase.browser_guid)
        expect(completion_purchase.referrer).to eq(deposit_purchase.referrer)
        expect(completion_purchase.quantity).to eq(deposit_purchase.quantity)
        expect(completion_purchase.was_product_recommended).to eq(deposit_purchase.was_product_recommended)
        expect(completion_purchase.seller).to eq(deposit_purchase.seller)
        expect(completion_purchase.credit_card_zipcode).to eq(deposit_purchase.credit_card_zipcode)
        expect(completion_purchase.affiliate).to eq(deposit_purchase.affiliate.try(:alive?) ? deposit_purchase.affiliate : nil)
        expect(completion_purchase.offer_code).to eq(deposit_purchase.offer_code)
        expect(completion_purchase.is_commission_completion_purchase).to be true
        expect(completion_purchase.tip.value_cents).to eq(20)
        expect(completion_purchase.variant_attributes).to eq(deposit_purchase.variant_attributes)
        expect(completion_purchase).to be_successful

        expect(commission.reload.status).to eq(Commission::STATUS_COMPLETED)
      end

      context "when the completion purchase fails" do
        it "marks the purchase as failed" do
          expect(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::IdempotencyError)

          expect { commission.create_completion_purchase! }.to raise_error(ActiveRecord::RecordInvalid)

          purchase = Purchase.last
          expect(purchase).to be_failed
          expect(purchase.is_commission_completion_purchase).to eq(true)
          expect(commission.reload.completion_purchase).to be_nil
        end
      end

      context "when the product price changes after the deposit purchase" do
        it "creates a completion purchase with the original price" do
          product.update!(price_cents: product.price_cents + 1000)

          expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

          completion_purchase = commission.reload.completion_purchase
          expect(completion_purchase.perceived_price_cents).to eq((deposit_purchase.price_cents / Commission::COMMISSION_DEPOSIT_PROPORTION) - deposit_purchase.price_cents)
        end
      end
    end

    context "when the product adds a new variant after the deposit purchase" do
      let!(:product) { create(:commission_product, price_cents: 1000) }

      let!(:deposit_purchase) { create(:commission_deposit_purchase, link: product) }
      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase: deposit_purchase) }

      it "creates a completion purchase without any variant attributes" do
        expect(deposit_purchase.variant_attributes).to be_empty
        expect(deposit_purchase.price_cents).to eq(500)
        create(:variant, price_difference_cents: 2000, variant_category: create(:variant_category, link: product))

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

        completion_purchase = commission.reload.completion_purchase
        expect(completion_purchase.price_cents).to eq(500)
      end
    end

    context "when the purchased variant has changed since the deposit purchase" do
      let!(:product) { create(:commission_product, price_cents: 1000) }
      let!(:category) { create(:variant_category, link: product, title: "Version") }
      let!(:variant) { create(:variant, variant_category: category, price_difference_cents: 1000) }

      let!(:deposit_purchase) { create(:commission_deposit_purchase, link: product, variant_attributes: [variant]) }
      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase: deposit_purchase) }

      context "variant price changed" do
        it "creates a completion purchase with the original price" do
          expect(deposit_purchase.price_cents).to eq(1000)

          Product::VariantsUpdaterService.new(
            product:,
            variants_params: [
              {
                id: category.external_id,
                name: category.title,
                options: [
                  {
                    id: variant.external_id,
                    name: variant.name,
                    price_difference_cents: 2000,
                  }
                ],
              }
            ]
          ).perform

          expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

          completion_purchase = commission.reload.completion_purchase
          expect(completion_purchase.price_cents).to eq(1000)
        end
      end

      context "variant soft deleted" do
        it "creates a completion purchase with the original price" do
          expect(deposit_purchase.price_cents).to eq(1000)

          variant.mark_deleted!

          expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

          completion_purchase = commission.reload.completion_purchase
          expect(completion_purchase.price_cents).to eq(1000)
        end
      end
    end

    context "when the deposit purchase used a discount code" do
      let!(:product) { create(:commission_product, price_cents: 2000) }
      let!(:offer_code) { create(:offer_code, products: [product], amount_cents: 1000) }

      let!(:deposit_purchase) { create(:commission_deposit_purchase, link: product, offer_code:, discount_code: offer_code.code) }
      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase: deposit_purchase) }

      it "creates a completion purchase with the original price" do
        expect(deposit_purchase.price_cents).to eq(500)

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

        completion_purchase = commission.reload.completion_purchase
        expect(completion_purchase.price_cents).to eq(500)
      end

      context "offer code has been soft deleted" do
        it "creates a completion purchase with the original price" do
          expect(deposit_purchase.price_cents).to eq(500)
          offer_code.mark_deleted!

          expect { commission.reload.create_completion_purchase! }.to change { Purchase.count }.by(1)

          completion_purchase = commission.reload.completion_purchase
          expect(completion_purchase.price_cents).to eq(500)
        end
      end

      context "offer code is single-use" do
        it "creates a completion purchase with the original price" do
          expect(deposit_purchase.price_cents).to eq(500)
          offer_code.update!(max_purchase_count: 1)

          expect { commission.reload.create_completion_purchase! }.to change { Purchase.count }.by(1)

          completion_purchase = commission.reload.completion_purchase
          expect(completion_purchase.price_cents).to eq(500)
        end
      end
    end

    context "when the deposit purchase has PPP discount applied" do
      before do
        PurchasingPowerParityService.new.set_factor("LV", 0.5)
      end

      let(:seller) do
        create(
          :user,
          :eligible_for_service_products,
          purchasing_power_parity_enabled: true,
          purchasing_power_parity_payment_verification_disabled: true
        )
      end
      let!(:product) { create(:commission_product, price_cents: 2000, user: seller) }

      let!(:deposit_purchase) do
        create(
          :commission_deposit_purchase,
          link: product,
          is_purchasing_power_parity_discounted: true,
          ip_country: "Latvia",
          card_country: "LV"
        ).tap do |purchase|
          purchase.create_purchasing_power_parity_info(factor: 0.5)
        end
      end

      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase:) }

      it "creates a completion purchase with PPP discount applied" do
        expect(deposit_purchase.is_purchasing_power_parity_discounted).to eq(true)
        expect(deposit_purchase.purchasing_power_parity_info).to be_present
        expect(deposit_purchase.purchasing_power_parity_info.factor).to eq(0.5)

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

        completion_purchase = commission.reload.completion_purchase
        expect(completion_purchase.is_purchasing_power_parity_discounted).to eq(true)
        expect(completion_purchase.purchasing_power_parity_info).to be_present
        expect(completion_purchase.purchasing_power_parity_info.factor).to eq(0.5)

        expect(completion_purchase.price_cents).to eq(500)
      end
    end
  end

  describe "#completion_price_cents" do
    let(:deposit_purchase) { create(:purchase, price_cents: 5000, is_commission_deposit_purchase: true) }
    let(:commission) { create(:commission, deposit_purchase: deposit_purchase) }

    it "returns the correct completion price" do
      expect(commission.completion_price_cents).to eq(5000)
    end
  end

  describe "statuses" do
    let(:commission) { build(:commission) }

    describe "#is_in_progress?" do
      it "returns true if the status is in_progress" do
        commission.status = Commission::STATUS_IN_PROGRESS
        expect(commission.is_in_progress?).to be true
      end

      it "returns false if the status is completed or cancelled" do
        commission.status = Commission::STATUS_COMPLETED
        expect(commission.is_in_progress?).to be false

        commission.status = Commission::STATUS_CANCELLED
        expect(commission.is_in_progress?).to be false
      end
    end

    describe "#is_completed?" do
      it "returns true if the status is completed" do
        commission.status = Commission::STATUS_COMPLETED
        expect(commission.is_completed?).to be true
      end

      it "returns false if the status is in_progress or cancelled" do
        commission.status = Commission::STATUS_IN_PROGRESS
        expect(commission.is_completed?).to be false

        commission.status = Commission::STATUS_CANCELLED
        expect(commission.is_completed?).to be false
      end
    end

    describe "#is_cancelled?" do
      it "returns true if the status is cancelled" do
        commission.status = Commission::STATUS_CANCELLED
        expect(commission.is_cancelled?).to be true
      end

      it "returns false if the status is in_progress or completed" do
        commission.status = Commission::STATUS_IN_PROGRESS
        expect(commission.is_cancelled?).to be false

        commission.status = Commission::STATUS_COMPLETED
        expect(commission.is_cancelled?).to be false
      end
    end
  end

  describe "#completion_display_price_cents" do
    let(:deposit_purchase) { create(:purchase, displayed_price_cents: 5000, is_commission_deposit_purchase: true) }
    let(:commission) { create(:commission, deposit_purchase: deposit_purchase) }

    it "returns the correct completion price" do
      expect(commission.completion_display_price_cents).to eq(5000)
    end
  end
end
