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
        # Owned-product suppression lives in the mailer, so proving it takes delivering the mail
        # the scheduler enqueues rather than inspecting the enqueue.
        include ActiveJob::TestHelper

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

        # cart1 holds two seller1 products (one variant-specific) and one of seller2's; owning
        # every one of them is what leaves the cart with nothing to be reminded about.
        def own_everything_in_cart1
          create(:purchase, link: seller1_product1, email: cart1.user.email, purchaser: cart1.user)
          create(:purchase, link: seller1_product2, email: cart1.user.email, purchaser: cart1.user, variant_attributes: [seller1_product2_variant1])
          create(:purchase, link: seller2_product2, email: cart1.user.email, purchaser: cart1.user)
        end

        it "schedules emails for the matching abandoned carts belonging to both logged-in users and guest carts" do
          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(3).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart2.id, { seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end

        it "schedules the same emails when every cart id crosses a scan batch boundary" do
          # The abandoned-cart scan walks each day's window in id-ordered keyset batches
          # (gumroad-private#1198). Shrinking the batch size to 1 forces every cart onto its
          # own batch, proving the batched walk finds exactly the carts the unbatched scan did.
          stub_const("#{described_class}::SCAN_BATCH_SIZE", 1)

          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(3).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart2.id, { seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end

        it "enqueues a cart whose products the recipient already owns, leaving suppression to the mailer" do
          # Deliberate: CustomerMailer#abandoned_cart re-derives the owned-product filter per cart
          # at render time and has to, because the purchase can land between selection and delivery
          # (gumroad-private#1626). A second copy here decided nothing the mailer does not decide
          # again, and batching it 500 carts at a time is what killed the run (gumroad-private#2343).
          own_everything_in_cart1

          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart)
            .with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end

        it "sends nothing for a cart whose every product is owned, and leaves it eligible" do
          # guest_cart1 holds the same seller1 products under an unowned email, so the run staying
          # otherwise intact proves the filter keys on the recipient, not the products.
          own_everything_in_cart1

          perform_enqueued_jobs { described_class.new.perform }

          recipients = ActionMailer::Base.deliveries.flat_map(&:to)
          expect(recipients).to include(guest_cart1.email)
          expect(recipients).not_to include(cart1.user.email)

          # Not writing the SentAbandonedCartEmail marker is what keeps the cart in
          # Cart.abandoned, so a later reminder is still possible.
          expect(cart1.reload.sent_abandoned_cart_emails).to be_empty
          expect(cart1).to be_abandoned
        end

        it "sends an email for an all-owned cart once an unowned product is added to it" do
          own_everything_in_cart1
          perform_enqueued_jobs { described_class.new.perform }

          create(:cart_product, cart: cart1, product: seller2_product1)
          cart1.update!(updated_at: 2.days.ago) # adding to a cart touches it

          expect do
            perform_enqueued_jobs { described_class.new.perform }
          end.to change { cart1.reload.sent_abandoned_cart_emails.count }.by(1)
        end

        it "still sends when a refunded purchase is the only one for a carted product" do
          create(:purchase, :refunded, link: seller1_product1, email: cart1.user.email, purchaser: cart1.user)

          perform_enqueued_jobs { described_class.new.perform }

          expect(ActionMailer::Base.deliveries.flat_map(&:to)).to include(cart1.user.email)
        end

        it "does not walk workflows of sellers with no products in the abandoned carts" do
          # Workflow matching drives off the carted products' sellers; walking every
          # published workflow was the bulk of the runtime that kept the job from
          # finishing inside a deploy window (gumroad-private#1576).
          uncarted_seller = create(:user)
          create(:payment_completed, user: uncarted_seller)
          uncarted_product = create(:product, user: uncarted_seller)
          uncarted_workflow = create(:abandoned_cart_workflow, seller: uncarted_seller, published_at: 1.day.ago, bought_products: [uncarted_product.unique_permalink])

          walked_workflow_ids = []
          allow_any_instance_of(Workflow).to receive(:abandoned_cart_products).and_wrap_original do |original, **kwargs|
            walked_workflow_ids << original.receiver.id
            original.call(**kwargs)
          end

          described_class.new.perform

          expect(walked_workflow_ids).to include(seller1_abandoned_cart_workflow.id, seller2_abandoned_cart_workflow.id)
          expect(walked_workflow_ids).not_to include(uncarted_workflow.id)
        end
      end

      context "when the run is killed partway through the day windows" do
        it "has already scheduled emails for the days scanned before the kill" do
          # Each day's window is matched and delivered before the next is scanned, so a
          # deploy-window kill costs one day's chunk instead of the whole run
          # (gumroad-private#1576): a death on day 2 must not take day 1's sends with it.
          travel_to Time.current.noon do
            day1_cart = create(:cart)
            create(:cart_product, cart: day1_cart, product: seller1_product1)
            day1_cart.update!(updated_at: 25.hours.ago)

            day2_cart = create(:cart)
            create(:cart_product, cart: day2_cart, product: seller1_product1)
            day2_cart.update!(updated_at: 2.days.ago)

            job = described_class.new
            scanned_windows = 0
            allow(job).to receive(:abandoned_cart_ids).and_wrap_original do |original, window|
              scanned_windows += 1
              raise Sidekiq::Shutdown if scanned_windows > 1
              original.call(window)
            end

            expect do
              expect { job.perform }.to raise_error(Sidekiq::Shutdown)
            end.to have_enqueued_mail(CustomerMailer, :abandoned_cart)
              .with(day1_cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id] }.stringify_keys)
          end
        end
      end

      context "when the matching carts outnumber the per-run ceiling" do
        # Deferring is safe because a delivered cart drops out of Cart.abandoned, so the next run
        # resumes past it rather than repeating it.
        it "stops at the ceiling and spends it on the newest window" do
          travel_to Time.current.noon do
            newest_cart = create(:cart)
            create(:cart_product, cart: newest_cart, product: seller1_product1)
            newest_cart.update!(updated_at: 25.hours.ago)

            older_cart = create(:cart)
            create(:cart_product, cart: older_cart, product: seller1_product1)
            older_cart.update!(updated_at: 3.days.ago)

            stub_const("#{described_class}::MAX_EMAILS_PER_RUN", 1)

            expect do
              described_class.new.perform
            end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).once
              .and have_enqueued_mail(CustomerMailer, :abandoned_cart)
                .with(newest_cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id] }.stringify_keys)
          end
        end

        it "picks the deferred carts up on the next run" do
          travel_to Time.current.noon do
            newest_cart = create(:cart)
            create(:cart_product, cart: newest_cart, product: seller1_product1)
            newest_cart.update!(updated_at: 25.hours.ago)

            older_cart = create(:cart)
            create(:cart_product, cart: older_cart, product: seller1_product1)
            older_cart.update!(updated_at: 3.days.ago)

            stub_const("#{described_class}::MAX_EMAILS_PER_RUN", 1)
            described_class.new.perform

            # Stands in for the first run's delivery: this row is what takes the cart out of
            # Cart.abandoned.
            create(:sent_abandoned_cart_email, cart: newest_cart, installment: seller1_abandoned_cart_workflow.alive_installments.sole)

            expect do
              described_class.new.perform
            end.to have_enqueued_mail(CustomerMailer, :abandoned_cart)
              .with(older_cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id] }.stringify_keys)
          end
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

  describe "retries-exhausted alerting" do
    it "reports to Sentry when retries are exhausted" do
      # The job failed silently every day for 3.5 months (gumroad-private#1198) because
      # dead-set failures produced no signal; this locks in the explicit alert.
      exception = WithMaxExecutionTime::QueryTimeoutError.new("maximum statement execution time exceeded")
      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("ScheduleAbandonedCartEmailsJob exhausted retries"),
        hash_including(exception_class: "WithMaxExecutionTime::QueryTimeoutError", exception_message: exception.message)
      )

      described_class.sidekiq_retries_exhausted_block.call(
        { "class" => described_class.name, "args" => [], "enqueued_at" => Time.current.to_f },
        exception
      )
    end
  end

  describe "lock configuration" do
    # A SIGKILL leaves the `until_executed` digest behind with no expiry, and this job's
    # digest is constant because it takes no arguments — so a single strand muted the job
    # platform-wide until cleared by hand (gumroad-private#1576). The TTL must stay under
    # the 24h schedule so an expiring strand cannot race the next day's enqueue.
    it "bounds the until_executed lock with a TTL shorter than the daily schedule" do
      opts = described_class.sidekiq_options

      expect(opts["lock"].to_sym).to eq(:until_executed)
      expect(opts["lock_ttl"]).to be_positive
      expect(opts["lock_ttl"]).to be < 1.day.to_i
    end
  end
end
