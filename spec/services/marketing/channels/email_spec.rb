# frozen_string_literal: true

require "spec_helper"

describe Marketing::Channels::Email do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:utm_link) { create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id) }
  let(:action) { create(:marketing_action, user: seller, link: product, channel: "email", utm_link:) }

  before do
    create(:payment_completed, user: seller)
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
  end

  it "returns the draft's edit path and posts nothing" do
    result = described_class.new(action).call

    draft = seller.installments.alive.find_by(installment_type: Installment::AUDIENCE_TYPE)
    expect(result.action).to eq(action)
    expect(result.edit_url).to eq(Rails.application.routes.url_helpers.edit_email_path(draft.external_id))
    expect(result.intent_url).to be_nil
    expect(result.connect_path).to be_nil
  end

  it "returns no edit path for a seller who cannot email yet" do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(0)

    expect(described_class.new(action).call.edit_url).to be_nil
  end
  describe "stale email execution" do
    it "refuses a separately cancelled action before creating a draft" do
      action.link
      Marketing::Action.find(action.id).cancel!

      expect { described_class.new(action).call }.to raise_error(StandardError, "This launch email is no longer available.")
      expect(seller.installments.count).to eq(0)
      expect(action.reload).to be_cancelled
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    it "refuses a separately unpublished product before creating a draft" do
      action.link
      Link.find(product.id).update!(draft: true)

      expect { described_class.new(action).call }.to raise_error(StandardError, "This launch email is no longer available.")
      expect(seller.installments.count).to eq(0)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    it "refuses a product that changed owners" do
      action.link
      Link.find(product.id).update!(user: create(:user))

      expect { described_class.new(action).call }.to raise_error(StandardError, "This launch email is no longer available.")
      expect(seller.installments.count).to eq(0)
    end

    it "does not replace a deleted draft on execute" do
      described_class.new(action).call
      seller.installments.sole.mark_deleted!

      expect { expect(described_class.new(action).call.edit_url).to be_nil }.not_to change(Installment, :count)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    it "returns the scheduled seller-edited draft without changing or sending it" do
      described_class.new(action).call
      draft = seller.installments.sole
      draft.update!(name: "Seller subject", message: "<p>Seller copy</p>", ready_to_publish: true)
      original = draft.attributes

      result = described_class.new(action, confirmation_token: action.confirmation_token).call

      expect(result.edit_url).to eq(Rails.application.routes.url_helpers.edit_email_path(draft.external_id))
      expect(draft.reload.attributes).to eq(original)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      expect(PostEmailBlast.count).to eq(0)
    end
  end
end
