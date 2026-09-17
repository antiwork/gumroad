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
      it "describes the email and the delay before anything is turned on" do
        expect(cart.state).to eq(
          available: true,
          blocked_reason: nil,
          enabled: false,
          account_wide: false,
          subject: "You left something in your cart",
          delay_hours: 24,
          workflow_url: nil,
        )
      end
    end

    describe "#enable" do
      it "creates and publishes the standard abandoned-cart workflow for this product" do
        expect { cart.enable }.to change { workflows.published.count }.from(0).to(1)

        workflow = workflows.sole
        expect(workflow).to be_published
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
        expect(cart.state).to include(enabled: true, account_wide: false)
      end

      it "reuses the account-wide cart workflow the seller already has, and says so" do
        DefaultAbandonedCartWorkflowGeneratorService.new(seller:).generate
        default_workflow = workflows.published.sole

        expect { described_class.new(product:, seller:).enable }
          .not_to change { [workflows.count, Installment.count] }

        state = described_class.new(product:, seller:).state
        expect(state).to include(enabled: true, account_wide: true)
        expect(state[:workflow_url]).to eq(workflow_emails_path(default_workflow.external_id))
      end

      it "leaves a workflow that covers a different product alone" do
        other = create(:workflow, seller:, link: nil, workflow_type: Workflow::ABANDONED_CART_TYPE,
                                  bought_products: [other_product.unique_permalink])
        other.publish!

        cart.enable

        expect(other.reload).to be_published
        expect(workflows.count).to eq(2)
        expect(described_class.new(product:, seller:).covering_workflow).not_to eq(other)
      end

      it "does not widen the email gate: a seller below the sales bar can still turn it on" do
        expect(seller.eligible_to_send_emails?).to eq(false)
        expect(seller.eligible_for_abandoned_cart_workflows?).to eq(true)

        expect(cart.enable).to be_published
        expect(cart.state).to include(enabled: true)
      end

      it "publishes the workflow's exempt email rather than refusing it" do
        workflow = cart.enable

        expect(workflow.installments.alive.sole).to be_abandoned_cart_type
        expect(workflow).to be_published
      end
    end

    describe "#pause" do
      it "pauses the workflow without deleting it or its email" do
        workflow = cart.enable
        installment = workflow.installments.alive.sole

        expect { cart.pause }.to change { workflows.published.count }.from(1).to(0)

        expect(workflow.reload).not_to be_published
        expect(workflow.deleted_at).to be_nil
        expect(installment.reload).to be_present
        expect(installment.deleted_at).to be_nil
        expect(cart.state).to include(enabled: false)
      end

      it "turns the same workflow back on instead of creating another" do
        workflow = cart.enable
        cart.pause

        expect { cart.enable }.not_to change { workflows.count }
        expect(workflow.reload).to be_published
      end

      it "does nothing when cart recovery was never on" do
        expect { cart.pause }.not_to change { [workflows.count, Installment.count] }
      end
    end
  end

  context "for a seller without a completed payout" do
    it "refuses to enable anything and explains why" do
      expect(cart).not_to be_available

      expect { cart.enable }.not_to change { [workflows.count, Installment.count] }
      expect(cart.enable).to eq(:blocked)
      expect(cart.state).to include(available: false, enabled: false)
      expect(cart.state[:blocked_reason]).to eq("Cart reminders turn on once you've received your first payout.")
    end

    it "refuses to pause anything" do
      expect(cart.pause).to eq(:blocked)
    end
  end
end
