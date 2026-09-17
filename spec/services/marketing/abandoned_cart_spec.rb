# frozen_string_literal: true

require "spec_helper"

describe Marketing::AbandonedCart do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, name: "Gumstein Letters") }
  let!(:other_product) { create(:product, user: seller, name: "Other Letters") }

  subject(:cart) { described_class.new(product:, seller:) }

  def workflows = seller.workflows.alive.abandoned_cart_type

  context "for a seller with a completed payout" do
    before { create(:payment_completed, user: seller) }

    describe "#state" do
      it "previews the saved subject and body after an email edit" do
        workflow = cart.enable
        workflow.installments.alive.sole.update!(name: "Your workbook is waiting", message: "<p>Return to your workbook.</p>")
        cart.pause

        expect(cart.state).to include(subject: "Your workbook is waiting", message: "<p>Return to your workbook.</p>")
        cart.enable
        expect(workflow.installments.alive.sole.reload.name).to eq("Your workbook is waiting")
      end

      it "describes the email and the delay before anything is turned on" do
        expect(cart.state).to include(
          available: true,
          blocked_reason: nil,
          enabled: false,
          can_toggle: true,
          subject: "You left something in your cart",
          delay_hours: 24,
          workflows: [],
        )
      end
    end

    describe "#enable" do
      it "creates and publishes the standard abandoned-cart workflow for this product" do
        expect { cart.enable }.to change { workflows.published.count }.from(0).to(1)

        workflow = workflows.sole
        expect(workflow.published_at).to be_present
        expect(workflow.bought_products).to eq([product.unique_permalink])
        expect(workflow.abandoned_cart_products(only_product_and_variant_ids: true).map(&:first)).to eq([product.id])

        installment = workflow.installments.alive.sole
        expect(installment).to be_abandoned_cart_type
        expect(installment.name).to eq("You left something in your cart")
        expect(installment.message).to eq(
          DefaultAbandonedCartWorkflowGeneratorService.default_message(checkout_url: checkout_url(host: DOMAIN))
        )
        expect(installment.send_emails?).to eq(true)
        expect(installment.installment_rule.displayable_time_duration).to eq(24)
        expect(installment.installment_rule.time_period).to eq("hour")
      end

      it "is idempotent: a second enable publishes no second workflow" do
        first = cart.enable

        expect { described_class.new(product:, seller:).enable }
          .not_to change { [workflows.count, Installment.count] }
        expect(described_class.new(product:, seller:).enable).to eq(first)
        expect(cart.state).to include(enabled: true, can_toggle: true)
      end

      it "leaves an account-wide workflow under Workflows control" do
        DefaultAbandonedCartWorkflowGeneratorService.new(seller:).generate
        workflow = workflows.published.sole

        expect(cart.enable).to eq(:blocked)
        expect(cart.pause).to eq(:blocked)
        expect(workflow.reload.published_at).to be_present
        expect(cart.state).to include(enabled: true, can_toggle: false)
        expect(cart.state[:workflows]).to contain_exactly(
          name: workflow.name, url: workflow_emails_path(workflow.external_id), scope: "All products", enabled: true
        )
      end

      it "leaves a workflow that covers a different product alone" do
        other = create(:workflow, seller:, link: nil, workflow_type: Workflow::ABANDONED_CART_TYPE,
                                  bought_products: [other_product.unique_permalink])
        other.publish!

        cart.enable

        expect(other.reload.published_at).to be_present
        expect(workflows.count).to eq(2)
        expect(described_class.new(product:, seller:).covering_workflow).not_to eq(other)
      end

      it "does not widen the email gate: a seller below the sales bar can still turn it on" do
        expect(seller.eligible_to_send_emails?).to eq(false)
        expect(seller.eligible_for_abandoned_cart_workflows?).to eq(true)

        expect(cart.enable.published_at).to be_present
        expect(cart.state).to include(enabled: true)
      end

      it "publishes the workflow's exempt email rather than refusing it" do
        workflow = cart.enable

        expect(workflow.installments.alive.sole).to be_abandoned_cart_type
        expect(workflow.published_at).to be_present
      end
    end

    describe "#pause" do
      it "pauses the workflow without deleting it or its email" do
        workflow = cart.enable
        installment = workflow.installments.alive.sole

        expect { cart.pause }.to change { workflows.published.count }.from(1).to(0)

        expect(workflow.reload.published_at).to be_nil
        expect(workflow.deleted_at).to be_nil
        expect(installment.reload).to be_present
        expect(installment.deleted_at).to be_nil
        expect(cart.state).to include(enabled: false)
      end

      it "turns the same workflow back on instead of creating another" do
        workflow = cart.enable
        cart.pause

        expect { cart.enable }.not_to change { workflows.count }
        expect(workflow.reload.published_at).to be_present
      end

      it "does nothing when cart recovery was never on" do
        expect { cart.pause }.not_to change { [workflows.count, Installment.count] }
      end

      it "does not pause overlapping workflows" do
        scoped = cart.enable
        other = create(:workflow, seller:, link: nil, workflow_type: Workflow::ABANDONED_CART_TYPE,
                                  bought_products: [product.unique_permalink])
        other.publish!

        expect(cart.pause).to eq(:blocked)
        expect(scoped.reload.published_at).to be_present
        expect(other.reload.published_at).to be_present
        expect(cart.state).to include(enabled: true, can_toggle: false)
      end

      it "does not enable or pause a workflow that covers another product" do
        workflow = cart.enable
        workflow.update!(bought_products: [product.unique_permalink, other_product.unique_permalink])

        expect(cart.pause).to eq(:blocked)
        expect(workflow.reload.published_at).to be_present
        workflow.unpublish!
        expect(cart.enable).to eq(:blocked)
        expect(workflow.reload.published_at).to be_nil
        expect(cart.state[:workflows].sole[:scope]).to include(product.name, other_product.name)
      end

      it "keeps filtered versions under Workflows control" do
        workflow = cart.enable
        variant = create(:variant, variant_category: create(:variant_category, link: product))
        workflow.update!(not_bought_variants: [variant.external_id])

        expect(cart.pause).to eq(:blocked)
        expect(cart.state[:can_toggle]).to eq(false)
        expect(cart.state[:workflows].sole[:scope]).to start_with("Selected versions of")
      end
    end
  end

  context "for a seller without a completed payout" do
    it "refuses to enable anything and explains why" do
      expect(cart).not_to be_available

      expect { cart.enable }.not_to change { [workflows.count, Installment.count] }
      expect(cart.enable).to eq(:blocked)
      expect(cart.state).to include(available: false, enabled: false)
      expect(cart.state[:blocked_reason]).to eq("Available after your first payout.")
    end

    it "does not need eligibility to pause something already published" do
      payment = create(:payment_completed, user: seller)
      workflow = cart.enable
      payment.destroy!
      seller.reload

      expect(cart).not_to be_available
      expect { cart.pause }.to change { workflows.published.count }.from(1).to(0)

      expect(workflow.reload.published_at).to be_nil
      expect(cart.state).to include(available: false, enabled: false)
    end

    it "pauses nothing when there is nothing published" do
      expect { cart.pause }.not_to change { workflows.count }
    end
  end

  describe "reviewed activation" do
    before { create(:payment_completed, user: seller) }

    def paused_workflow
      workflow = cart.enable
      cart.pause
      workflow
    end

    it "returns a stable token with the saved preview" do
      workflow = paused_workflow
      snapshot = cart.state
      expect(snapshot[:activation_token]).to match(/\A[0-9a-f]{64}\z/)
      expect(described_class.new(product:, seller:).state[:activation_token]).to eq(snapshot[:activation_token])
      expect(cart.enable(expected_activation_token: snapshot[:activation_token])).to eq(workflow)
    end

    %i[name message].each do |field|
      it "rejects a saved #{field} changed after preview" do
        workflow = paused_workflow
        token = cart.state[:activation_token]
        workflow.installments.sole.update!(field => "Changed after review")
        expect(cart.enable(expected_activation_token: token)).to eq(:stale)
        expect(workflow.reload.published_at).to be_nil
      end
    end

    it "rejects a different workflow after the reviewed filter no longer covers this product" do
      workflow = paused_workflow
      token = cart.state[:activation_token]
      workflow.update!(bought_products: [other_product.unique_permalink])
      expect { expect(cart.enable(expected_activation_token: token)).to eq(:stale) }.not_to change(Workflow, :count)
      expect(workflow.reload.published_at).to be_nil
    end

    it "rejects a deleted and replaced email even when its text is identical" do
      workflow = paused_workflow
      token = cart.state[:activation_token]
      email = workflow.installments.sole
      email.mark_deleted!
      workflow.installments.create!(name: email.name, message: email.message, installment_type: email.installment_type, seller:, send_emails: true)
      expect(cart.enable(expected_activation_token: token)).to eq(:stale)
      expect(workflow.reload.published_at).to be_nil
    end

    it "keeps preview content and token on the same email snapshot" do
      workflow = paused_workflow
      original = described_class.new(product:, seller:).state
      allow_any_instance_of(Installment).to receive(:message_with_inline_abandoned_cart_products).and_wrap_original do |method, **args|
        Installment.find(workflow.installments.sole.id).update!(message: "New saved content")
        method.call(**args)
      end
      snapshot = cart.state
      expect(snapshot[:message]).to eq(original[:message])
      expect(snapshot[:activation_token]).to eq(original[:activation_token])
      expect(cart.enable(expected_activation_token: snapshot[:activation_token])).to eq(:stale)
    end

    it "canonicalizes saved filter ordering without losing filter changes" do
      workflow = paused_workflow
      workflow.update!(bought_products: [product.unique_permalink, other_product.unique_permalink])
      first = described_class.new(product:, seller:).state[:activation_token]
      workflow.update!(bought_products: [other_product.unique_permalink, product.unique_permalink])
      expect(described_class.new(product:, seller:).state[:activation_token]).to eq(first)
      workflow.update!(not_bought_products: [other_product.unique_permalink])
      expect(described_class.new(product:, seller:).state[:activation_token]).not_to eq(first)
    end
  end
end
