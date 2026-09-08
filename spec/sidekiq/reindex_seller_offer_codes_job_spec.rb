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
    $redis.set("#{key}:lock", "another-worker", ex: 3600)
    expect(ProductOfferCodeIndexingService).not_to receive(:new)
    job.perform(seller.id)
    expect($redis.get("#{key}:lock")).to eq("another-worker")
    expect(described_class.jobs.any? { _1["at"].present? }).to be(true)
    expect($redis.get("#{key}:version")).to eq("1")
  end

  it "updates old and new applicability after currency changes, exclusions, detachment and destruction" do
    products = [create(:product, user: seller, price_cents: 1000), create(:product, user: seller, price_currency_type: "eur", price_cents: 1000)]
    code = create(:universal_offer_code, user: seller, code: "DISCOUNT")
    verify = lambda do
      4.times { run_batch }
      products.each do |product|
        actual = product.__elasticsearch__.client.get(index: Link.index_name, id: product.id).dig("_source", "offer_codes")
        expect(actual).to eq(product.reload.build_search_update(["offer_codes"])["offer_codes"])
      end
    end
    verify.call
    code.update!(currency_type: "eur")
    verify.call
    code.update!(excluded_products: [products.last])
    verify.call
    code.update!(excluded_products: [])
    verify.call
    code.update!(universal: false, products: [products.last])
    verify.call
    code.update!(products: [products.first], currency_type: "usd")
    verify.call
    code.destroy!
    verify.call
  end

  it "coalesces repeated saves of a large catalogue without a catch-up burst" do
    stub_const("ReindexSellerOfferCodesJob::BATCH_SIZE", 25)
    products = create_list(:product, 1001, user: seller, price_cents: 1000)
    code = create(:universal_offer_code, user: seller, code: "INITIAL")
    SidekiqUniqueJobs.use_config(enabled: true) do
      10.times { |i| code.update!(code: "SAVE#{i}") }
      expect(described_class.jobs.count { _1["args"] == [seller.id] }).to be <= 2
    end
    batches = []
    allow(ProductOfferCodeIndexingService).to receive(:new).and_wrap_original do |original, batch|
      batches << batch.size
      original.call(batch)
    end
    job.perform(seller.id)
    20.times { job.perform(seller.id) }
    expect(batches).to eq([25])
    travel described_class::INTERVAL
    41.times { run_batch }
    expect(batches.sum).to eq(products.size)
    expect(batches.max).to eq(25)
    expect($redis.get("#{key}:version")).to be_nil
    [products.first, products.last].each do |product|
      expect(product.__elasticsearch__.client.get(index: Link.index_name, id: product.id).dig("_source", "offer_codes")).to eq(["SAVE9"])
    end
  end

  it "serializes competing worker executions using the shared Redis semaphore" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    entered = Queue.new
    finish = Queue.new
    calls = Queue.new
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) do
      calls << true
      entered << true
      finish.pop
    end
    first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { described_class.new.perform(seller.id) } }
    entered.pop
    second = Thread.new { described_class.new.perform(seller.id) }
    second.value
    expect(calls.size).to eq(1)
  ensure
    finish << true if finish
    first&.value
  end

  it "admits only one simultaneous first acquisition of a missing lock" do
    seller_id = seller.id
    described_class.enqueue(seller_id)
    ready = Queue.new
    start = Queue.new
    entered = Queue.new
    finish = Queue.new
    calls = Queue.new
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) do
      calls << true
      entered << true
      finish.pop
    end
    workers = 2.times.map do
      Thread.new do
        ready << true
        start.pop
        ActiveRecord::Base.connection_pool.with_connection { described_class.new.perform(seller_id) }
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    Timeout.timeout(5) { entered.pop }
    Timeout.timeout(5) { Thread.pass until workers.any? { !_1.alive? } }
    expect(calls.size).to eq(1)
  ensure
    2.times { finish << true } if finish
    workers&.each(&:value)
  end

  it "resumes preserved work after retry exhaustion without a tight retry loop" do
    described_class.enqueue(seller.id)
    described_class.clear
    described_class.sidekiq_retries_exhausted_block.call({ "args" => [seller.id] }, RuntimeError.new)
    expect(ReindexSellerOfferCodesRecoveryJob).to have_enqueued_sidekiq_job(seller.id).at(1.hour.from_now)
    expect($redis.get("#{key}:version")).to eq("1")
  end

  it "schedules exhaustion recovery even while the failed job holds its unique lock" do
    SidekiqUniqueJobs.use_config(enabled: true) do
      described_class.enqueue(seller.id)
      message = described_class.jobs.first
      described_class.clear
      middleware = SidekiqUniqueJobs::Middleware::Server.new
      expect do
        middleware.call(described_class.new, message, "low") { raise "index unavailable" }
      end.to raise_error("index unavailable")
      expect(described_class.perform_async(seller.id)).to be_nil
      described_class.sidekiq_retries_exhausted_block.call(message, RuntimeError.new)
      expect(ReindexSellerOfferCodesRecoveryJob.jobs.size).to eq(1)
      expect(ReindexSellerOfferCodesRecoveryJob.jobs.first["lock"]).to be_nil
    end
  end

  it "skips deleted catalogue rows without consuming batch capacity" do
    deleted = create_list(:product, 3, user: seller)
    deleted.each { _1.update_columns(deleted_at: Time.current) }
    active = create(:product, user: seller)
    described_class.enqueue(seller.id)
    expect(ProductOfferCodeIndexingService).to receive(:new).with([active]).and_call_original
    run_batch
    expect($redis.get("#{key}:version")).to be_nil
  end

  it "updates only targeted products and preserves an in-flight targeted edit" do
    products = create_list(:product, 3, user: seller)
    code = create(:offer_code, user: seller, products: [products.last], code: "BEFORE")
    processed = []
    allow(ProductOfferCodeIndexingService).to receive(:new).and_wrap_original do |original, batch|
      processed.concat(batch.map(&:id))
      original.call(batch)
    end
    run_batch
    expect(processed).to eq([products.last.id])
    expect($redis.get("#{key}:version")).to be_nil
    described_class.enqueue_products(seller.id, [products.last.id])
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) { code.update!(code: "AFTER") }
    run_batch
    expect($redis.zrange("#{key}:products", 0, -1)).to eq([products.last.id.to_s])
  end

  it "advances the catalogue despite a targeted edit before every execution" do
    products = create_list(:product, 3, user: seller)
    described_class.enqueue(seller.id)
    6.times do
      described_class.enqueue_products(seller.id, [products.last.id])
      run_batch
    end
    expect($redis.get("#{key}:version")).to be_nil
  end

  it "paces retries after a slow partial indexing failure" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    calls = 0
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) do
      calls += 1
      travel 10.seconds
      raise "partial failure"
    end
    expect { job.perform(seller.id) }.to raise_error("partial failure")
    job.perform(seller.id)
    expect(calls).to eq(1)
    expect($redis.get("#{key}:version")).to eq("1")
  end

  it "does not reuse product IDs from a rolled-back destruction" do
    products = create_list(:product, 2, user: seller)
    code = create(:offer_code, user: seller, products: [products.first])
    run_batch
    OfferCode.transaction(requires_new: true) do
      code.destroy!
      raise ActiveRecord::Rollback
    end
    code.reload.update!(products: [products.last])
    expect($redis.zrange("#{key}:products", 0, -1)).to include(products.last.id.to_s)
    3.times { run_batch }
    expect(products.last.__elasticsearch__.client.get(index: Link.index_name, id: products.last.id).dig("_source", "offer_codes")).to include(code.code)
  end

  it "moves hot targeted products behind older pending work" do
    products = create_list(:product, 5, user: seller)
    described_class.enqueue_products(seller.id, products.map(&:id))
    processed = []
    allow(ProductOfferCodeIndexingService).to receive(:new).and_wrap_original do |original, batch|
      processed.concat(batch.map(&:id))
      described_class.enqueue_products(seller.id, products.map(&:id))
      original.call(batch)
    end
    3.times { run_batch }
    expect(processed.uniq).to match_array(products.map(&:id))
  end

  it "releases its lock when the final cooldown write fails" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    allow($redis).to receive(:set).and_call_original
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) do
      allow($redis).to receive(:set).with("#{key}:cooldown", anything, ex: anything).and_raise(Redis::BaseError, "unavailable")
    end
    expect { job.perform(seller.id) }.to raise_error(Redis::BaseError)
    expect($redis.get("#{key}:lock")).to be_nil
  end

  it "does not acknowledge work after losing its lease" do
    create(:product, user: seller)
    described_class.enqueue(seller.id)
    allow_any_instance_of(ProductOfferCodeIndexingService).to receive(:perform) do
      $redis.set("#{key}:lock", "replacement-worker", ex: 600)
    end
    expect { job.perform(seller.id) }.to raise_error(described_class::LockLost)
    expect($redis.get("#{key}:version")).to eq("1")
    expect($redis.get("#{key}:lock")).to eq("replacement-worker")
  end

  it "advances the cursor when one product in a batch fails to index" do
    products = create_list(:product, 3, user: seller, price_cents: 1000)
    create(:universal_offer_code, user: seller, code: "KEEP")
    described_class.enqueue(seller.id)
    allow(ProductOfferCodeIndexingService).to receive(:new).and_wrap_original do |original, batch|
      service = original.call(batch)
      allow(service).to receive(:perform).and_wrap_original do |perform_original, &block|
        batch.each do |product|
          next unless product.id == products.first.id
          allow(product.__elasticsearch__).to receive(:update_document_attributes).and_raise(
            Elasticsearch::Transport::Transport::Errors::BadRequest, "mapper_parsing_exception"
          )
        end
        perform_original.call(&block)
      end
      service
    end
    expect(ErrorNotifier).to receive(:notify).with(
      an_instance_of(Elasticsearch::Transport::Transport::Errors::BadRequest),
      product_id: products.first.id,
      user_id: seller.id
    )
    run_batch
    expect($redis.get("#{key}:cursor")).to eq(products.second.id.to_s)
    expect(products.second.__elasticsearch__.client.get(index: Link.index_name, id: products.second.id).dig("_source", "offer_codes")).to include("KEEP")
    2.times { run_batch }
    expect(products.third.__elasticsearch__.client.get(index: Link.index_name, id: products.third.id).dig("_source", "offer_codes")).to include("KEEP")
    expect($redis.get("#{key}:version")).to be_nil
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
