# frozen_string_literal: true

require "spec_helper"

describe PreorderLink do
  describe "#release!" do
    before do
      @product = create(:product_with_pdf_file, price_cents: 600, is_in_preorder_state: true)
      create(:rich_content, entity: @product, description: [{ "type" => "fileEmbed", "attrs" => { "id" => @product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
      @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now)
    end

    it "does not allow the product to be released if the release date hasn't arrived yet" do
      expect(@preorder_link.release!).to be(false)
      expect(@preorder_link.reload.state).to eq "unreleased"
    end

    it "allows the product to be released if the release date is within a minute" do
      @preorder_link.update_attribute(:release_at, 30.seconds.from_now)
      expect(@preorder_link.release!).to be(true)
      expect(@preorder_link.reload.state).to eq "released"
    end

    it "does not allow the product to be released if the release date is not within a minute" do
      @preorder_link.update_attribute(:release_at, 70.seconds.from_now)
      expect(@preorder_link.release!).to be(false)
      expect(@preorder_link.reload.state).to eq "unreleased"
    end

    it "does not allow the product to be released if the product is banned" do
      @preorder_link.update_attribute(:release_at, Time.current)
      @preorder_link.link.update(banned_at: Time.current)

      expect(@preorder_link.release!).to be(false)
      expect(@preorder_link.reload.state).to eq "unreleased"
    end

    it "doesn't allow the product to be released if the product is unpublished" do
      @preorder_link.update_attribute(:release_at, Time.current)
      @preorder_link.link.update_column(:purchase_disabled_at, Time.current)

      expect(@preorder_link.release!).to be(false)
      expect(@preorder_link.reload.state).to eq "unreleased"
    end

    it "allows the unpublished product to be released if it's being released manually" do
      @preorder_link.update_attribute(:release_at, Time.current)
      @preorder_link.link.update_column(:purchase_disabled_at, Time.current)
      @preorder_link.is_being_manually_released_by_the_seller = true

      expect(@preorder_link.release!).to be(true)
      expect(@preorder_link.reload.state).to eq "released"
    end

    it "doesn't allow the product to be released if the product is deleted" do
      @preorder_link.update_attribute(:release_at, Time.current)
      @preorder_link.link.update_column(:deleted_at, Time.current)

      expect(@preorder_link.release!).to be(false)
      expect(@preorder_link.reload.state).to eq "unreleased"
    end

    it "allows the product to be released if the release date is in the future but it's being released by the seller" do
      @preorder_link.is_being_manually_released_by_the_seller = true
      expect(@preorder_link.release!).to be(true)
      expect(@preorder_link.reload.state).to eq "released"
    end

    describe "regular preorder" do
      it "does not allow the product to be released if the product does not have rich content" do
        @preorder_link.update_attribute(:release_at, Time.current)
        @product.alive_rich_contents.find_each(&:mark_deleted!)
        expect(@preorder_link.release!).to be(false)
        expect(@preorder_link.reload.state).to eq "unreleased"
      end
    end

    describe "physical preorder" do
      before do
        @product.update!(is_physical: true, require_shipping: true)
        @product.save_files!([])
      end

      it "allows releasing the product even if it does not have any delivery content" do
        @preorder_link.update_attribute(:release_at, Time.current)

        expect(@preorder_link.release!).to be(true)
        expect(@preorder_link.reload.state).to eq "released"
      end
    end

    context "when purchasing a preorder twice with different version selections", :vcr do
      before do
        variant_category = create(:variant_category, link: @product)
        large_variant = create(:variant, variant_category:)
        create(:rich_content, entity: large_variant, description: [{ "type" => "fileEmbed", "attrs" => { "id" => @product.product_files.first.external_id, "uid" => SecureRandom.uuid } }])
        small_variant = create(:variant, name: "Small", variant_category:)
        create(:rich_content, entity: small_variant, description: [{ "type" => "paragraph" }])

        # Purchase the large variant
        auth_large_variant = build(:purchase, link: @product, chargeable: build(:chargeable), purchase_state: "in_progress",
                                              is_preorder_authorization: true, variant_attributes: [large_variant])
        preorder = @preorder_link.build_preorder(auth_large_variant)
        preorder.authorize!
        expect(preorder.errors.full_messages).to be_empty
        preorder.mark_authorization_successful

        @email = auth_large_variant.email

        # Purchase the small variant
        auth_small_variant = build(:purchase, link: @product, chargeable: build(:chargeable), purchase_state: "in_progress",
                                              email: @email, is_preorder_authorization: true, variant_attributes: [small_variant])
        preorder = @preorder_link.build_preorder(auth_small_variant)
        preorder.authorize!
        expect(preorder.errors.full_messages).to be_empty
        preorder.mark_authorization_successful
      end

      it "releases the preorder and charges both purchases", :sidekiq_inline do
        @preorder_link.is_being_manually_released_by_the_seller = true

        expect do
          expect(@preorder_link.release!).to be(true)
        end.to change { Purchase.successful.by_email(@email).count }.by(2)
        expect(@preorder_link.reload.state).to eq "released"
      end
    end

    it "marks the link as released" do
      @preorder_link.update_attribute(:release_at, Time.current) # bypass validation
      @preorder_link.release!
      expect(@preorder_link.reload.state).to eq "released"
      expect(@preorder_link.link.is_in_preorder_state?).to be(false)
    end

    it "adds the proper job to the queue when it comes time to charge the preorders" do
      @preorder_link.update_attribute(:release_at, Time.current)
      @preorder_link.release!

      expect(ChargeSuccessfulPreordersWorker).to have_enqueued_sidekiq_job(@preorder_link.id)
    end
  end

  describe "#revenue_cents" do
    before do
      @product = create(:product, price_cents: 600, is_in_preorder_state: false)
      @preorder_product = create(:preorder_product_with_content, link: @product)
      @preorder_product.update(release_at: Time.current) # bypassed the creation validation
      @good_card = build(:chargeable)
      @incorrect_cvc_card = build(:chargeable_decline)
      @good_card_but_cant_charge = build(:chargeable_success_charge_decline)
    end

    it "returns the correct revenue", :vcr do
      # first preorder fails to authorize
      authorization_purchase = build(:purchase, link: @product, chargeable: @incorrect_cvc_card,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_failed

      # second preorder authorizes and charges successfully
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress",
                                                is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      preorder.charge!
      preorder.mark_charge_successful

      # third preorder authorizes successfully but the charge fails
      authorization_purchase = build(:purchase, link: @product, chargeable: @good_card_but_cant_charge,
                                                purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = @preorder_product.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful
      preorder.charge!

      expect(@preorder_product.revenue_cents).to eq 600
    end
  end
end
