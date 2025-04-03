# frozen_string_literal: true

require "spec_helper"

describe ScheduleAbandonedCartEmailsJob do
  describe "#perform" do
    let(:seller1) { create(:user) }
    let!(:seller1_payment) { create(:payment_completed, user: seller1) }
    let!(:seller1_product1) { create(:product, user: seller1) }
    let!(:seller1_product2) { create(:product, user: seller1) }
    let(:seller1_product2_variant_category) { create(:variant_category, link: seller1_product2) }
    let!(:seller1_product2_variant1) { create(:variant, variant_category: seller1_product2_variant_category) }
    let!(:seller1_product2_variant2) { create(:variant, variant_category: seller1_product2_variant_category) }
    let!(:seller1_abandoned_cart_workflow) { create(:abandoned_cart_workflow, seller: seller1, published_at: 1.day.ago, bought_products: [seller1_product1.unique_permalink], bought_variants: [seller1_product2_variant1.external_id]) }
    let(:seller2) { create(:user) }
    let!(:seller2_payment) { create(:payment_completed, user: seller2) }
    let!(:seller2_product1) { create(:product, user: seller2) }
    let!(:seller2_product2) { create(:product, user: seller2) }
    let!(:seller2_abandoned_cart_workflow) { create(:abandoned_cart_workflow, seller: seller2, published_at: 1.day.ago, bought_products: [seller2_product1.unique_permalink]) }

    context "when there are no abandoned carts" do
      it "does not schedule any emails" do
        create(:cart)
        expect { described_class.new.perform }.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
      end
    end

    context "when there are abandoned carts" do
      context "when there are no matching abandoned cart workflows" do
        it "does not schedule any emails" do
          cart = create(:cart, updated_at: 2.days.ago)
          create(:cart_product, cart:, product: seller1_product1)
          create(:cart_product, cart:)
          seller1_abandoned_cart_workflow.unpublish!

          expect { described_class.new.perform }.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
        end
      end

      context "when there are matching abandoned cart workflows" do
        let(:cart1) { create(:cart) }
        let!(:cart1_product1) { create(:cart_product, cart: cart1, product: seller1_product1) }
        let!(:cart1_product2) { create(:cart_product, cart: cart1, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:cart1_product3) { create(:cart_product, cart: cart1, product: seller2_product2) }
        let(:cart2) { create(:cart) }
        let!(:cart2_product1) { create(:cart_product, cart: cart2, product: seller2_product1) }
        let!(:cart2_product2) { create(:cart_product, cart: cart2, product: seller1_product2, option: seller1_product2_variant2) }
        let(:cart3) { create(:cart) }
        let!(:cart3_product1) { create(:cart_product, cart: cart3, product: seller1_product2) }
        let(:guest_cart1) { create(:cart, :guest, email: "guest1@example.com") }
        let!(:guest_cart1_product1) { create(:cart_product, cart: guest_cart1, product: seller1_product1) }
        let!(:guest_cart1_product2) { create(:cart_product, cart: guest_cart1, product: seller1_product2, option: seller1_product2_variant1) }
        let(:guest_cart2) { create(:cart, :guest, email: "") } # ignores this guest cart due to absence of email
        let!(:guest_cart2_product1) { create(:cart_product, cart: guest_cart2, product: seller2_product1) }
        let(:guest_cart3) { create(:cart, :guest, email: "guest3@example.com") }
        let!(:guest_cart3_product1) { create(:cart_product, cart: guest_cart3, product: seller1_product2) }
        let!(:guest_cart4) { create(:cart, :guest, email: "guest4@example.com") }

        before do
          cart1.update!(updated_at: 2.days.ago)
          cart2.update!(updated_at: 25.hours.ago)
          cart3.update!(updated_at: 21.hours.ago)
          guest_cart1.update!(updated_at: 2.days.ago)
          guest_cart2.update!(updated_at: 25.hours.ago)
          guest_cart3.update!(updated_at: 21.hours.ago)
          guest_cart4.update!(updated_at: 2.days.ago)
        end

        it "schedules emails for the matching abandoned carts belonging to both logged-in users and guest carts" do
          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(3).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart2.id, { seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end
      end

      context "when there are multiple matching abandoned cart workflows for a cart" do
        let(:cart) { create(:cart) }
        let!(:cart_product1) { create(:cart_product, cart: cart, product: seller1_product1) }
        let!(:cart_product2) { create(:cart_product, cart: cart, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:cart_product3) { create(:cart_product, cart: cart, product: seller2_product1) }
        let!(:cart_product4) { create(:cart_product, cart: cart, product: seller2_product2) }
        let(:guest_cart) { create(:cart, :guest, email: "guest@example.com") }
        let!(:guest_cart_product1) { create(:cart_product, cart: guest_cart, product: seller1_product1) }
        let!(:guest_cart_product2) { create(:cart_product, cart: guest_cart, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:guest_cart_product3) { create(:cart_product, cart: guest_cart, product: seller2_product1) }
        let!(:guest_cart_product4) { create(:cart_product, cart: guest_cart, product: seller2_product2) }

        before do
          cart.update!(updated_at: 2.days.ago)
          guest_cart.update!(updated_at: 2.days.ago)
        end

        it "schedules only one email for each of the corresponding carts" do
          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(2).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id], seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id], seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
        end
      end
    end

    context "when seller is not eligible for abandoned cart workflows" do
      let(:cart) { create(:cart) }
      let!(:cart_product) { create(:cart_product, cart: cart, product: seller1_product1) }
      let(:guest_cart) { create(:cart, :guest, email: "guest@example.com") }
      let!(:guest_cart_product) { create(:cart_product, cart: guest_cart, product: seller1_product1) }

      before do
        cart.update!(updated_at: 2.days.ago)
        guest_cart.update!(updated_at: 2.days.ago)
        allow_any_instance_of(User).to receive(:eligible_for_abandoned_cart_workflows?).and_return(false)
      end

      it "does not schedule any abandoned cart emails" do
        expect do
          described_class.new.perform
        end.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
      end
    end
  end
end
