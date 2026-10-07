# frozen_string_literal: true

require "spec_helper"

describe SubmitPaypalDisputeEvidenceJob do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "PAYERID123") }
  let(:product) { create(:product, user: seller, name: "Recipe Pack") }
  let(:purchase) do
    create(:purchase, link: product, seller:, merchant_account:,
                      charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                      created_at: Time.utc(2026, 9, 26, 19, 35, 26))
  end
  let(:dispute) do
    create(:dispute, purchase:, charge_processor_id: PaypalChargeProcessor.charge_processor_id,
                     charge_processor_dispute_id: "PP-R-ABC-1", state: "formalized")
  end
  let(:api) { instance_double(PaypalRestApi) }
  let(:offered) { OpenStruct.new(status_code: 200, result: { "links" => [{ "rel" => "self" }, { "rel" => "provide_supporting_info" }] }) }
  let(:not_offered) { OpenStruct.new(status_code: 200, result: { "links" => [{ "rel" => "self" }, { "rel" => "accept_claim" }, { "rel" => "make_offer" }] }) }
  let(:accepted) { OpenStruct.new(status_code: 200, result: {}) }

  before do
    Feature.activate(:submit_paypal_dispute_evidence)
    allow(PaypalRestApi).to receive(:new).and_return(api)
    allow(api).to receive(:successful_response?) { |r| (200...300).include?(r.status_code) }
    $redis.del(described_class.claim_key(dispute.id))
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "view", created_at: Time.utc(2026, 9, 26, 19, 35, 51))
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", created_at: Time.utc(2026, 9, 26, 19, 35, 53))
  end

  it "sends the delivery record when PayPal offers provide_supporting_info" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    expect(api).to receive(:provide_dispute_supporting_info) do |dispute_id:, merchant_account:, notes:|
      expect(dispute_id).to eq "PP-R-ABC-1"
      expect(merchant_account.charge_processor_merchant_id).to eq "PAYERID123"
      expect(notes).to include "Recipe Pack (Gumroad order #{purchase.external_id}, paid 2026-09-26 19:35:26)"
      expect(notes).to include "download page opened 2026-09-26 19:35:51; file downloaded 2026-09-26 19:35:53"
      accepted
    end

    described_class.new.perform(dispute.id)
  end

  it "submits only once across repeated runs" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    expect(api).to receive(:provide_dispute_supporting_info).once.and_return(accepted)

    described_class.new.perform(dispute.id)
    described_class.new.perform(dispute.id)
  end

  it "does nothing when PayPal does not offer the action" do
    allow(api).to receive(:fetch_dispute).and_return(not_offered)
    expect(api).not_to receive(:provide_dispute_supporting_info)

    described_class.new.perform(dispute.id)
  end

  it "releases the claim when PayPal rejects the note so a later run can retry" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    allow(api).to receive(:provide_dispute_supporting_info).and_return(OpenStruct.new(status_code: 422, result: {}), accepted)
    expect(ErrorNotifier).to receive(:notify).once

    described_class.new.perform(dispute.id)
    described_class.new.perform(dispute.id)
    expect(api).to have_received(:provide_dispute_supporting_info).twice
  end

  it "does nothing when the buyer never opened the order" do
    ConsumptionEvent.where(purchase_id: purchase.id).delete_all
    expect(api).not_to receive(:fetch_dispute)

    described_class.new.perform(dispute.id)
  end

  it "does nothing once the dispute is decided" do
    dispute.update!(won_at: Time.current)
    expect(api).not_to receive(:fetch_dispute)

    described_class.new.perform(dispute.id)
  end

  it "does nothing while the feature flag is off" do
    Feature.deactivate(:submit_paypal_dispute_evidence)
    expect(PaypalRestApi).not_to receive(:new)

    described_class.new.perform(dispute.id)
  end
end
