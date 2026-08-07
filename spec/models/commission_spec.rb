# frozen_string_literal: true

describe Commission, :vcr do
  def attach_commission_file(commission)
    commission.files.attach(file_fixture("test.pdf"))
  end

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

    context "when a completion purchase already exists" do
      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }

      before { attach_commission_file(commission) }

      # `create_completion_purchase!` leaves the commission in_progress while the charge settles
      # in the buyer's presentment currency, so a second complete request lands on a commission
      # whose buyer has already been charged.
      it "does not charge the buyer again while the completion charge is still settling" do
        settling_purchase = create(:purchase, link: commission.deposit_purchase.link, seller: commission.deposit_purchase.seller, is_commission_completion_purchase: true)
        commission.update!(completion_purchase: settling_purchase)

        expect { commission.create_completion_purchase! }.not_to change { Purchase.count }

        expect(commission.reload.completion_purchase).to eq(settling_purchase)
        expect(commission.status).to eq(Commission::STATUS_IN_PROGRESS)
      end

      it "retries the charge when the previous completion attempt failed" do
        commission.update!(completion_purchase: create(:failed_purchase, link: commission.deposit_purchase.link, seller: commission.deposit_purchase.seller, is_commission_completion_purchase: true))
        expect_any_instance_of(Purchase).to receive(:process!) do |purchase|
          purchase.errors.add(:base, "Stop before charging")
        end

        expect { commission.create_completion_purchase! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context "when no deliverable files are attached" do
      let!(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }

      it "refuses to create a completion purchase" do
        expect do
          commission.create_completion_purchase!
        end.to raise_error(ActiveRecord::RecordInvalid) { |error|
          expect(error.record.errors.full_messages).to eq(["Attach at least one file before completing this commission."])
        }.and not_change { Purchase.count }

        expect(commission.reload.completion_purchase).to be_nil
        expect(commission.status).to eq(Commission::STATUS_IN_PROGRESS)
      end
    end

    it "makes the commission's stored presentment available while processing the completion purchase" do
      product = create(:commission_product)
      merchant_account = create(:merchant_account, user: product.user, charge_processor_merchant_id: "commission-presentment-test")
      deposit_purchase = create(:purchase, link: product, merchant_account:, is_commission_deposit_purchase: true)
      commission = create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase:)
      attach_commission_file(commission)
      fixing = create(:later_charge_presentment, owner: commission, canonical_price_cents: deposit_purchase.price_cents)
      expect_any_instance_of(Purchase).to receive(:process!) do |completion_purchase|
        expect(completion_purchase.commission.current_later_charge_presentment).to eq(fixing)
        completion_purchase.errors.add(:base, "Stop before charging")
      end

      expect { commission.create_completion_purchase! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    # Tip USD must be set on the completion tip: LaterChargePresentment.canonical_price_cents_for
    # subtracts tip.value_usd_cents, and a 0 default would make a principal-only fixing look stale.
    it "persists completion tip USD so a buyer-presentment fixing still matches when tipped" do
      product = create(:commission_product)
      merchant_account = create(:merchant_account, user: product.user, charge_processor_merchant_id: "commission-tip-usd-presentment")
      deposit_purchase = create(
        :purchase,
        link: product,
        merchant_account:,
        is_commission_deposit_purchase: true,
        price_cents: 1_100,
        total_transaction_cents: 1_100
      )
      # Distinct presentment vs USD proves we do not copy value_cents into value_usd_cents.
      deposit_purchase.create_tip!(value_cents: 80, value_usd_cents: 100)
      commission = create(:commission, status: Commission::STATUS_IN_PROGRESS, deposit_purchase:)
      attach_commission_file(commission)
      fixing = create(
        :later_charge_presentment,
        owner: commission,
        presentment_currency: "eur",
        presentment_price_cents: 899,
        canonical_price_cents: 1_000
      )

      expect_any_instance_of(Purchase).to receive(:process!) do |completion_purchase|
        expect(completion_purchase.tip.value_cents).to eq(80)
        expect(completion_purchase.tip.value_usd_cents).to eq(100)
        completion_purchase.price_cents = 1_000
        completion_purchase.total_transaction_cents = 1_100
        expect(LaterChargePresentment.canonical_price_cents_for(completion_purchase))
          .to eq(fixing.canonical_price_cents)
        completion_purchase.errors.add(:base, "Stop before charging")
      end

      expect { commission.create_completion_purchase! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    context "when the deposit is no longer chargeable" do
      let(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }
      let(:deposit_purchase) { commission.deposit_purchase }

      # Refunding the deposit is what the Help Center tells sellers to do to reject a commission,
      # and nothing transitions the commission when they do — so the completion button stays live.
      it "refuses to charge when the deposit was fully refunded" do
        deposit_purchase.update!(stripe_refunded: true)

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }

        expect(commission.reload.completion_purchase).to be_nil
        expect(commission.status).to eq(Commission::STATUS_IN_PROGRESS)
      end

      it "refuses to charge when the deposit was refunded through a different instance after this one was loaded" do
        deposit_purchase # memoize the association before the refund lands elsewhere
        Purchase.find(deposit_purchase.id).update!(stripe_refunded: true)

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }
      end

      it "refuses to charge when the deposit was partially refunded" do
        deposit_purchase.update!(stripe_partially_refunded: true)

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }
      end

      it "refuses to charge when the deposit was charged back" do
        deposit_purchase.update!(chargeback_date: Date.today)

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }
      end

      # A reversed chargeback leaves the deposit good, so it must NOT block — otherwise winning a
      # dispute would strand the commission.
      it "still charges when a chargeback was reversed" do
        deposit_purchase.update!(chargeback_date: Date.today, chargeback_reversed: true)
        attach_commission_file(commission)

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)
        expect(commission.reload.status).to eq(Commission::STATUS_COMPLETED)
      end

      it "refuses to charge when the deposit never succeeded" do
        deposit_purchase.update_columns(purchase_state: "failed")

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }
      end

      it "refuses to charge a cancelled commission" do
        commission.update!(status: Commission::STATUS_CANCELLED)

        expect { commission.create_completion_purchase! }
          .to raise_error(ActiveRecord::RecordInvalid, /deposit is no longer in a completable state/)
          .and not_change { Purchase.count }
      end

      # A seller buying their own commission product gets a `test_successful` deposit; completing
      # it charges nothing but is a supported flow, so the state gate must admit it.
      it "still charges when the deposit is a seller test purchase" do
        deposit_purchase.update_columns(purchase_state: "test_successful")
        attach_commission_file(commission)

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)
        expect(commission.reload.status).to eq(Commission::STATUS_COMPLETED)
      end
    end

    context "when status is not completed" do
      let(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }
      let(:deposit_purchase) { commission.deposit_purchase }
      let(:product) { deposit_purchase.link }

      before do
        attach_commission_file(commission)
        deposit_purchase.update!(zip_code: "10001")
        deposit_purchase.update!(displayed_price_cents: 100)
        # Distinct presentment vs USD proves we do not copy value_cents into value_usd_cents.
        deposit_purchase.create_tip!(value_cents: 20, value_usd_cents: 25)
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
        expect(completion_purchase.tip.value_usd_cents).to eq(25)
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

      before { attach_commission_file(commission) }

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

      before { attach_commission_file(commission) }

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

      before { attach_commission_file(commission) }

      it "creates a completion purchase with the original price" do
        expect(deposit_purchase.price_cents).to eq(500)
        offer_code.update!(max_purchase_count: 10, once_per_cart: true)
        deposit_purchase.purchase_offer_code_discount.update!(once_per_cart: true)
        offer_code.update!(once_per_cart: false)

        expect { commission.create_completion_purchase! }.to change { Purchase.count }.by(1)

        completion_purchase = commission.reload.completion_purchase
        expect(completion_purchase.price_cents).to eq(500)
        expect(completion_purchase.purchase_offer_code_discount.once_per_cart).to be(true)
        expect(offer_code.reload.times_used).to eq(1)
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

      before { attach_commission_file(commission) }

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

  describe "#files_are_editable?" do
    let(:commission) { create(:commission, status: Commission::STATUS_IN_PROGRESS) }

    it "returns true while the commission is in progress with no completion charge" do
      expect(commission.files_are_editable?).to be true
    end

    it "returns false once the commission is completed" do
      commission.status = Commission::STATUS_COMPLETED
      expect(commission.files_are_editable?).to be false
    end

    it "returns false while the completion charge is still settling" do
      commission.update!(completion_purchase: create(:purchase, link: commission.deposit_purchase.link, seller: commission.deposit_purchase.seller, is_commission_completion_purchase: true))

      expect(commission.files_are_editable?).to be false
      expect(commission.status).to eq(Commission::STATUS_IN_PROGRESS)
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
