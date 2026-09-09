# frozen_string_literal: true

require "spec_helper"

describe ReindexSellerOfferCodesRecoveryJob do
  it "resumes the preserved cursor through the same bounded worker" do
    seller = create(:user)
    products = create_list(:product, 3, user: seller)
    ReindexSellerOfferCodesJob.enqueue(seller.id)
    $redis.set("offer_code_index:#{seller.id}:cursor", products.first.id)
    $redis.set("offer_code_index:#{seller.id}:scan_version", "1")
    expect(ProductOfferCodeIndexingService).to receive(:new).with(products.last(2)).and_call_original

    described_class.new.perform(seller.id)

    expect($redis.get("offer_code_index:#{seller.id}:version")).to be_nil
    expect(ReindexSellerOfferCodesJob.jobs.any? { _1["at"].present? }).to be(true)
  end

  it "retains a delayed recovery after a prolonged outage exhausts its own retries" do
    freeze_time
    described_class.sidekiq_retries_exhausted_block.call({ "args" => [123] }, RuntimeError.new)
    expect(described_class).to have_enqueued_sidekiq_job(123).at(1.hour.from_now)
  end

  it "does not bypass an active seller lock" do
    seller = create(:user)
    ReindexSellerOfferCodesJob.enqueue(seller.id)
    $redis.set("offer_code_index:#{seller.id}:lock", "active-worker", ex: 600)
    expect(ProductOfferCodeIndexingService).not_to receive(:new)

    described_class.new.perform(seller.id)

    expect($redis.get("offer_code_index:#{seller.id}:version")).to eq("1")
    expect($redis.get("offer_code_index:#{seller.id}:lock")).to eq("active-worker")
  end

  it "propagates an indexing failure for Sidekiq retry without acknowledging work" do
    seller = create(:user)
    create(:product, user: seller)
    ReindexSellerOfferCodesJob.enqueue(seller.id)
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform).and_raise("unavailable")

    expect { described_class.new.perform(seller.id) }.to raise_error("unavailable")
    expect($redis.get("offer_code_index:#{seller.id}:version")).to eq("1")
  end
end
