# frozen_string_literal: true

require "spec_helper"

describe DefaultAbandonedCartWorkflowGeneratorService do
  include Rails.application.routes.url_helpers

  let(:seller) { create(:user) }

  subject { described_class.new(seller:) }

  describe "#generate" do
    context "when seller does not have an abandoned cart workflow" do
      it "creates a new abandoned cart workflow and publishes it" do
        expect do
          subject.generate
        end.to change { seller.workflows.abandoned_cart_type.published.count }.from(0).to(1)

        workflow = seller.workflows.abandoned_cart_type.published.sole
        expect(workflow.name).to eq("Abandoned cart")
        expect(workflow.bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        installment = workflow.installments.alive.sole
        expect(installment.name).to eq("You left something in your cart")
        expect(installment.message).to eq(%Q(<p>When you're ready to buy, <a href="#{checkout_url(host: DOMAIN)}" target="_blank" rel="noopener noreferrer nofollow">complete checking out</a>.</p><product-list-placeholder />))
        expect(installment.abandoned_cart_type?).to be(true)
        expect(installment.installment_rule.displayable_time_duration).to eq(24)
        expect(installment.installment_rule.time_period).to eq("hour")
      end
    end

    context "when seller already has an abandoned cart workflow" do
      before do
        create(:workflow, seller:, workflow_type: Workflow::ABANDONED_CART_TYPE, deleted_at: 1.hour.ago)
      end

      it "does not create a new abandoned cart workflow" do
        expect do
          expect do
            expect do
              subject.generate
            end.to_not change { seller.workflows.abandoned_cart_type.count }
          end.to_not change { Installment.count }
        end.to_not change { InstallmentRule.count }
      end
    end
  end
end
