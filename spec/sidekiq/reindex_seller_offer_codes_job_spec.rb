# frozen_string_literal: true

require "spec_helper"

describe ReindexSellerOfferCodesJob do
  let(:seller) { create(:user) }
  let(:key) { "offer_code_index:#{seller.id}" }
  let(:job) { described_class.new }

  before do
    freeze_time
    stub_const("ReindexSellerOfferCodesJob::BATCH_SIZE", 2)
  end

  def run_batch
    job.perform(seller.id)
    travel ReindexSellerOfferCodesJob::INTERVAL
  end

  it "bounds actual work across queued duplicates and resumes from the last batch" do
    products = create_list(:product, 5, user: seller)
    10.times { described_class.enqueue(seller.id) }
    batches = []
    allow(ProductOfferCodeIndexingService).to receive(:new).and_wrap_original do |original, batch|
      batches << batch.map(&:id)
      original.call(batch)
    end
    job.perform(seller.id)
    10.times { job.perform(seller.id) }
    expect(batches).to eq([products.first(2).map(&:id)])
    travel described_class::INTERVAL
    3.times { run_batch }
    expect(batches.flatten).to eq(products.map(&:id))
    expect($redis.get("#{key}:version")).to be_nil
    expect(SendToElasticsearchWorker.jobs.select { _1["args"].last == ["offer_codes"] }).to be_empty
  end

  it "revisits products behind the cursor after a mid-flight edit" do
    products = create_list(:product, 3, user: seller)
    code = create(:universal_offer_code, user: seller, code: "BEFORE")
    run_batch
    code.update!(code: "AFTER")
    4.times { run_batch }
    products.each do |product|
      expect(product.__elasticsearch__.client.get(index: Link.index_name, id: product.id).dig("_source", "offer_codes")).to include("AFTER")
    end
    expect($redis.get("#{key}:version")).to be_nil
  end

  it "retains the cursor and dirty generation when indexing fails" do
    create_list(:product, 3, user: seller)
    described_class.enqueue(seller.id)
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform).and_raise("index unavailable")
    expect { job.perform(seller.id) }.to raise_error("index unavailable")
    expect($redis.get("#{key}:cursor")).to be_nil
    expect($redis.get("#{key}:version")).to eq("1")
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform).and_call_original
    3.times { run_batch }
    expect($redis.get("#{key}:version")).to be_nil
  end

  it "does not acknowledge a batch if scheduling its continuation fails" do
    create_list(:product, 3, user: seller)
    described_class.enqueue(seller.id)
    allow(described_class).to receive(:perform_in).and_raise("queue unavailable")
    expect { job.perform(seller.id) }.to raise_error("queue unavailable")
    expect($redis.get("#{key}:cursor")).to be_nil
    expect($redis.get("#{key}:version")).to eq("1")
  end

  it "does no work while another process holds the seller semaphore" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    semaphore = Suo::Client::Redis.new("#{key}:lock", client: $redis)
    semaphore.lock do
      expect(ProductOfferCodeIndexingService).not_to receive(:new)
      job.perform(seller.id)
    end
    expect(described_class.jobs.any? { _1["at"].present? }).to be(true)
    expect($redis.get("#{key}:version")).to eq("1")
  end

  it "preserves an edit arriving during the final batch" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) { described_class.enqueue(seller.id) }
    run_batch
    expect($redis.get("#{key}:version")).to eq("2")
    expect($redis.get("#{key}:cursor")).to be_nil
  end
end
