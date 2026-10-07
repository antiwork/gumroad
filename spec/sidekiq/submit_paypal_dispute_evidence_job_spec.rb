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
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "view", consumed_at: Time.utc(2026, 9, 26, 19, 35, 51))
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 19, 35, 53))
  end

  it "sends the delivery record when PayPal offers provide_supporting_info" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    expect(api).to receive(:provide_dispute_supporting_info) do |dispute_id:, merchant_account:, notes:|
      expect(dispute_id).to eq "PP-R-ABC-1"
      expect(merchant_account.charge_processor_merchant_id).to eq "PAYERID123"
      expect(notes).to include "Recipe Pack (Gumroad order #{purchase.external_id}, paid 2026-09-26 19:35:26)"
      expect(notes).to include "file downloaded 2026-09-26 19:35:53; download page opened 2026-09-26 19:35:51"
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

  it "releases the claim when the request raises before PayPal receives the note" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    allow(api).to receive(:provide_dispute_supporting_info).and_raise(Redis::BaseError, "down")

    expect { described_class.new.perform(dispute.id) }.to raise_error(Redis::BaseError)
    expect($redis.get(described_class.claim_key(dispute.id))).to be_nil
  end

  it "keeps a confirmed claim long-lived" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    allow(api).to receive(:provide_dispute_supporting_info).and_return(accepted)

    described_class.new.perform(dispute.id)
    expect($redis.ttl(described_class.claim_key(dispute.id))).to be > 1.day.to_i
  end

  it "includes reads and streams and reports consumed_at" do
    ConsumptionEvent.where(purchase_id: purchase.id).delete_all
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "read",
                               created_at: Time.utc(2026, 9, 27), consumed_at: Time.utc(2026, 9, 26, 20, 0, 0))

    notes = described_class.evidence_notes([purchase])
    expect(notes).to include "document read 2026-09-26 20:00:00"
  end

  it "keeps download proof when page opens exceed the cap" do
    ConsumptionEvent.where(purchase_id: purchase.id).delete_all
    8.times do |i|
      create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "view", consumed_at: Time.utc(2026, 9, 26, 19, 40 + i))
    end
    create(:consumption_event, purchase_id: purchase.id, link_id: product.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 20, 0))

    notes = described_class.evidence_notes([purchase])
    expect(notes).to include "file downloaded 2026-09-26 20:00:00"
    expect(notes).to include "3 more entries not listed"
  end

  it "counts downloads recorded against bundle member purchases" do
    ConsumptionEvent.where(purchase_id: purchase.id).delete_all
    member = create(:free_purchase, link: create(:product, user: seller, price_cents: 0))
    allow(purchase).to receive(:is_bundle_purchase?).and_return(true)
    allow(purchase).to receive(:product_purchases).and_return([member])
    create(:consumption_event, purchase_id: member.id, link_id: member.link.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 21, 0))

    expect(described_class.evidence_notes([purchase])).to include "file downloaded 2026-09-26 21:00:00"
  end

  it "does not post again when PayPal already holds our note" do
    held = OpenStruct.new(status_code: 200, result: { "links" => [{ "rel" => "provide_supporting_info" }],
                                                      "supporting_info" => [{ "notes" => "#{described_class::NOTES_HEADER}\n..." }] })
    allow(api).to receive(:fetch_dispute).and_return(held)
    expect(api).not_to receive(:provide_dispute_supporting_info)

    described_class.new.perform(dispute.id)
  end

  it "fits a multi-purchase note within PayPal's 2,000-character limit and keeps each download" do
    purchases = Array.new(3) do |n|
      p = create(:purchase, link: create(:product, user: seller, name: "A very long perfume recipe product name number #{n} " * 2), seller:, merchant_account:)
      20.times { |i| create(:consumption_event, purchase_id: p.id, link_id: p.link.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 20, i)) }
      5.times { |i| create(:consumption_event, purchase_id: p.id, link_id: p.link.id, url_redirect_id: 1, product_file_id: nil, event_type: "view", consumed_at: Time.utc(2026, 9, 26, 19, i)) }
      p
    end

    notes = described_class.evidence_notes(purchases)
    expect(notes.length).to be <= described_class::MAX_NOTES_LENGTH
    purchases.each { |p| expect(notes).to include "Gumroad order #{p.external_id}" }
    expect(notes.scan("file downloaded 2026-09-26 20:00:00").size).to eq 3
    expect(notes).to match(/\d+ more entries not listed/)
  end

  it "keeps a download for every item when many items have maximum-length names" do
    purchases = Array.new(7) do |n|
      p = create(:purchase, link: create(:product, user: seller, name: "#{n}" + "x" * 254), seller:, merchant_account:)
      3.times { |i| create(:consumption_event, purchase_id: p.id, link_id: p.link.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 20, i)) }
      p
    end

    notes = described_class.evidence_notes(purchases)
    expect(notes.length).to be <= described_class::MAX_NOTES_LENGTH
    purchases.each { |p| expect(notes).to match(/Gumroad order #{p.external_id}, paid [^)]+\): file downloaded 2026-09-26 20:00:00/) }
  end

  it "leaves an order with no recorded access out of the note instead of calling it unopened" do
    unopened = create(:purchase, link: create(:product, user: seller, name: "Unopened Pack"), seller:, merchant_account:)

    notes = described_class.evidence_notes([purchase, unopened])
    expect(notes).to include "Gumroad order #{purchase.external_id}"
    expect(notes).not_to include unopened.external_id
    expect(notes).not_to include "no access recorded"
    expect(described_class.evidence_notes([unopened])).to be_nil
  end

  it "reads PayPal's parsed response, where nested values are OpenStructs" do
    parsed = PayPalHttp::HttpClient.new(nil).send(:_parse_values, JSON.parse({
      links: [{ rel: "self" }, { rel: "provide_supporting_info" }],
      supporting_info: [{ notes: "#{described_class::NOTES_HEADER}\nRecipe Pack", source: "SUBMITTED_BY_PARTNER" }],
    }.to_json))

    expect(described_class.action_offered?(parsed)).to be true
    expect(described_class.already_submitted?(parsed)).to be true
    expect(described_class.already_submitted?(PayPalHttp::HttpClient.new(nil).send(:_parse_values, { "links" => [] }))).to be false
  end

  it "does not fail or retry when the long claim cannot be written after PayPal accepted the note" do
    allow(api).to receive(:fetch_dispute).and_return(offered)
    allow(api).to receive(:provide_dispute_supporting_info).and_return(accepted)
    allow($redis).to receive(:set).and_call_original
    allow($redis).to receive(:set).with(described_class.claim_key(dispute.id), anything, ex: described_class::CLAIM_TTL).and_raise(Redis::BaseError, "down")
    expect(ErrorNotifier).to receive(:notify).once

    expect { described_class.new.perform(dispute.id) }.not_to raise_error
    expect($redis.get(described_class.claim_key(dispute.id))).to be_present
  end

  it "sends nothing rather than an oversized note when too many orders share the charge" do
    purchases = Array.new(12) do |n|
      p = create(:purchase, link: create(:product, user: seller, name: "#{n}".ljust(255, "x")), seller:, merchant_account:)
      create(:consumption_event, purchase_id: p.id, link_id: p.link.id, url_redirect_id: 1, product_file_id: nil, event_type: "download", consumed_at: Time.utc(2026, 9, 26, 20))
      p
    end

    expect(described_class.evidence_notes(purchases)).to be_nil
  end

  [401, 403].each do |status|
    it "notifies and does not write when the live dispute read returns #{status}" do
      $redis.del("paypal_dispute_read_denied:#{merchant_account.id}")
      allow(api).to receive(:fetch_dispute).and_return(OpenStruct.new(status_code: status, result: {}))
      expect(api).not_to receive(:provide_dispute_supporting_info)
      expect(ErrorNotifier).to receive(:notify).once

      2.times { described_class.new.perform(dispute.id) }
    end
  end

  it "notifies once per merchant account, not once per dispute" do
    $redis.del("paypal_dispute_read_denied:#{merchant_account.id}")
    other_account = create(:merchant_account_paypal, user: create(:user), charge_processor_merchant_id: "PAYERID456")
    other_purchase = create(:purchase, link: create(:product, user: other_account.user), seller: other_account.user, merchant_account: other_account, charge_processor_id: PaypalChargeProcessor.charge_processor_id)
    other_dispute = create(:dispute, purchase: other_purchase, charge_processor_id: PaypalChargeProcessor.charge_processor_id, charge_processor_dispute_id: "PP-R-ABC-2", state: "formalized")
    create(:consumption_event, purchase_id: other_purchase.id, link_id: other_purchase.link_id, url_redirect_id: 1, product_file_id: nil, event_type: "download")
    $redis.del("paypal_dispute_read_denied:#{other_account.id}")
    allow(api).to receive(:fetch_dispute).and_return(OpenStruct.new(status_code: 403, result: {}))
    expect(ErrorNotifier).to receive(:notify).twice

    2.times { described_class.new.perform(dispute.id) }
    2.times { described_class.new.perform(other_dispute.id) }
  end

  [408, 429, 503].each do |status|
    it "raises on a PayPal #{status} sending the note and releases the claim so the retry can send it" do
      allow(api).to receive(:fetch_dispute).and_return(offered)
      allow(api).to receive(:provide_dispute_supporting_info).and_return(OpenStruct.new(status_code: status, result: {}), accepted)

      expect { described_class.new.perform(dispute.id) }.to raise_error(/PayPal returned #{status} sending/)
      expect($redis.get(described_class.claim_key(dispute.id))).to be_nil

      described_class.new.perform(dispute.id)
      expect(api).to have_received(:provide_dispute_supporting_info).twice
    end
  end

  it "stays quiet on a client error that is not an access problem" do
    allow(api).to receive(:fetch_dispute).and_return(OpenStruct.new(status_code: 422, result: {}))
    expect(api).not_to receive(:provide_dispute_supporting_info)
    expect(ErrorNotifier).not_to receive(:notify)

    expect { described_class.new.perform(dispute.id) }.not_to raise_error
  end

  [408, 429, 500, 503].each do |status|
    it "raises on a PayPal #{status} reading the dispute so Sidekiq retries" do
      allow(api).to receive(:fetch_dispute).and_return(OpenStruct.new(status_code: status, result: {}))
      expect(api).not_to receive(:provide_dispute_supporting_info)

      expect { described_class.new.perform(dispute.id) }.to raise_error(/PayPal returned #{status}/)
    end
  end

  it "spaces retries in minutes" do
    expect([0, 1, 2].map { |count| described_class.sidekiq_retry_in_block.call(count, StandardError.new) }).to eq([300, 600, 900])
  end

  it "stays quiet when the live dispute is gone" do
    allow(api).to receive(:fetch_dispute).and_return(OpenStruct.new(status_code: 404, result: {}))
    expect(api).not_to receive(:provide_dispute_supporting_info)
    expect(ErrorNotifier).not_to receive(:notify)

    described_class.new.perform(dispute.id)
  end

  it "reads the offered action from a PayPal client response object" do
    expect(described_class.action_offered?(OpenStruct.new(links: [OpenStruct.new(rel: "provide_supporting_info")]))).to be true
    expect(described_class.action_offered?(OpenStruct.new(links: [OpenStruct.new(rel: "accept_claim")]))).to be false
  end

  it "labels every consumption event type" do
    expect(described_class::ACCESS_LABELS.keys).to match_array(ConsumptionEvent::EVENT_TYPES)
  end
end
