# frozen_string_literal: true

require "spec_helper"

describe BundleProduct do
  describe "#standalone_price_cents" do
    let(:bundle_product) { create(:bundle_product, quantity: 2) }

    it "returns the correct price" do
      expect(bundle_product.standalone_price_cents).to eq(200)
    end

    context "when the product has a variant" do
      before do
        bundle_product.product = create(:product_with_digital_versions, user: bundle_product.bundle.user)
        bundle_product.variant = bundle_product.product.alive_variants.first
        bundle_product.variant.price_difference_cents = 100
      end

      it "returns the correct price" do
        expect(bundle_product.standalone_price_cents).to eq(400)
      end
    end
  end

  describe "#in_order" do
    let!(:bundle_product1) { create(:bundle_product, position: 1) }
    let!(:bundle_product2) { create(:bundle_product, position: 0) }
    let!(:bundle_product3) { create(:bundle_product, position: 2) }

    it "returns the bundle products in order" do
      expect(BundleProduct.where(id: [bundle_product1.id, bundle_product2.id, bundle_product3.id]).in_order)
        .to eq([bundle_product2, bundle_product1, bundle_product3])
    end
  end

  describe "validations" do
    let(:bundle_product) { create(:bundle_product) }

    context "when the product doesn't belong to the bundle's user" do
      before do
        bundle_product.product = create(:product)
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("The product must belong to the bundle's seller")
      end
    end

    context "when the product is versioned but no variant is set" do
      before do
        bundle_product.product = create(:product_with_digital_versions, user: bundle_product.bundle.user)
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("Bundle product must have variant specified for versioned product")
      end
    end

    context "when the product is versioned and a variant is set" do
      before do
        bundle_product.product = create(:product_with_digital_versions, user: bundle_product.bundle.user)
        bundle_product.variant = bundle_product.product.alive_variants.first
      end

      it "doesn't add an error" do
        expect(bundle_product).to be_valid
      end
    end

    context "when the variant doesn't belong to the product" do
      before do
        bundle_product.variant = create(:variant)
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("The bundle product's variant must belong to its product")
      end
    end

    context "when the product is a bundle" do
      before do
        bundle_product.product.is_bundle = true
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("A bundle product cannot be added to a bundle")
      end
    end

    context "when the product is a subscription" do
      before do
        bundle_product.product.is_recurring_billing = true
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("A subscription product cannot be added to a bundle")
      end
    end

    context "when the product is a call" do
      before do
        bundle_product.product = create(:call_product)
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages).to include("A call product cannot be added to a bundle")
      end
    end


    context "when a bundle product already exists for the product" do
      let(:duplicate_bundle_product) { build(:bundle_product, product: bundle_product.product, bundle: bundle_product.bundle) }

      it "adds an error" do
        expect(duplicate_bundle_product).to_not be_valid
        expect(duplicate_bundle_product.errors.full_messages.first).to eq("Product is already in bundle")
      end
    end

    context "when the bundle is not a bundle" do
      before do
        bundle_product.bundle.is_bundle = false
      end

      it "adds an error" do
        expect(bundle_product).to_not be_valid
        expect(bundle_product.errors.full_messages.first).to eq("Bundle products can only be added to bundles")
      end
    end

    context "when the bundle is a bundle" do
      before do
        bundle_product.bundle.is_bundle = true
      end

      it "doesn't add an error" do
        expect(bundle_product).to be_valid
      end
    end

    describe "installment plans" do
      let(:seller) { create(:user, :eligible_for_service_products) }
      let(:bundle) { create(:product, :bundle, user: seller, price_cents: 1000) }

      let(:eligible_product) { create(:product, native_type: Link::NATIVE_TYPE_DIGITAL, user: seller) }
      let(:ineligible_product) { create(:commission_product, user: seller) }

      context "when the bundle has an installment plan" do
        let!(:installment_plan) { create(:product_installment_plan, link: bundle) }

        context "when the product is eligible for installment plans" do
          it "doesn't add an error" do
            bundle_product = build(:bundle_product, bundle: bundle, product: eligible_product)
            expect(bundle_product).to be_valid
          end
        end

        context "when the product is not eligible for installment plans" do
          it "adds an error" do
            bundle_product = build(:bundle_product, bundle: bundle, product: ineligible_product)
            expect(bundle_product).not_to be_valid
            expect(bundle_product.errors.full_messages).to include("Installment plan is not available for the bundled product: #{ineligible_product.name}")
          end
        end
      end

      context "when the bundle has no installment plan" do
        it "doesn't validate product eligibility for installment plans" do
          bundle_product = build(:bundle_product, bundle: bundle, product: ineligible_product)
          expect(bundle_product).to be_valid
        end
      end
    end
  end
end
