# frozen_string_literal: true

describe Onetime::BackfillEmailEngagementDynamoTable do
  let(:client) { Aws::DynamoDB::Client.new(stub_responses: true) }
  let(:mailer_method) { "CreatorContactingCustomersMailer.purchase_installment" }
  let(:mailer_args) { "[123, 456]" }
  let(:recipient_digest) { Digest::SHA256.hexdigest("#{mailer_method}\n#{mailer_args}") }
  let(:click_url) { "https://example&#46;com/a" }
  let(:url_digest) { Digest::SHA256.hexdigest(click_url) }

  def progress_keys
    [described_class::OPENS_CURSOR_KEY, described_class::CLICKS_CURSOR_KEY].flat_map do |key|
      [key, "#{key}_total", "#{key}_processed"]
    end
  end

  before do
    EmailEngagementDynamoStore.client = client
    $redis.del(*progress_keys)
  end

  after do
    EmailEngagementDynamoStore.client = nil
    $redis.del(*progress_keys)
  end

  def requests
    client.api_requests
  end

  def written_items(request)
    request[:params][:request_items]["email_engagement"].map do |r|
      r[:put_request][:item].transform_values do |attribute_value|
        type, value = attribute_value.first
        type == :n ? Integer(value) : value
      end
    end
  end

  describe ".backfill_opens!" do
    it "writes OPEN# items with counts and the timestamp range, skipping docs without an installment" do
      opened_at = Time.utc(2026, 1, 5, 12)
      CreatorEmailOpenEvent.create!(
        installment_id: 123, mailer_method:, mailer_args:,
        open_count: 3, open_timestamps: [opened_at + 1.hour, opened_at]
      )
      CreatorEmailOpenEvent.create!(installment_id: nil, mailer_method:, mailer_args: "[9, 9]", open_count: 1)

      described_class.backfill_opens!

      expect(requests.map { _1[:operation_name] }).to eq([:batch_write_item])
      item = written_items(requests.first).sole
      expect(item).to include(
        "pk" => "123",
        "sk" => "OPEN##{recipient_digest}",
        "mailer_method" => mailer_method,
        "mailer_args" => mailer_args,
        "open_count" => 3,
        "first_open_at" => opened_at.iso8601(3),
        "last_open_at" => (opened_at + 1.hour).iso8601(3)
      )
    end

    it "resumes from the Redis cursor" do
      first = CreatorEmailOpenEvent.create!(installment_id: 1, mailer_method:, mailer_args: "[1, 1]", open_count: 1)
      second = CreatorEmailOpenEvent.create!(installment_id: 2, mailer_method:, mailer_args: "[2, 2]", open_count: 1)
      $redis.set(described_class::OPENS_CURSOR_KEY, first._id.to_s)

      described_class.backfill_opens!

      expect(written_items(requests.sole).sole["pk"]).to eq("2")
      expect($redis.get(described_class::OPENS_CURSOR_KEY)).to eq(second._id.to_s)
    end

    it "continues the progress percentage across a restart" do
      first = CreatorEmailOpenEvent.create!(installment_id: 1, mailer_method:, mailer_args: "[1, 1]", open_count: 1)
      CreatorEmailOpenEvent.create!(installment_id: 2, mailer_method:, mailer_args: "[2, 2]", open_count: 1)
      # State left behind by an interrupted earlier run: 5 of 10 docs done.
      $redis.set(described_class::OPENS_CURSOR_KEY, first._id.to_s)
      $redis.set("#{described_class::OPENS_CURSOR_KEY}_total", 10)
      $redis.set("#{described_class::OPENS_CURSOR_KEY}_processed", 5)
      stub_const("#{described_class}::PROGRESS_INTERVAL", 1)

      expect { described_class.backfill_opens! }
        .to output(%r{CreatorEmailOpenEvent: 6/10 \(60\.0%\)}).to_stdout

      expect($redis.get("#{described_class::OPENS_CURSOR_KEY}_processed")).to eq("6")
      expect($redis.get("#{described_class::OPENS_CURSOR_KEY}_total")).to eq("10")
    end

    it "retries unprocessed items before giving up" do
      CreatorEmailOpenEvent.create!(installment_id: 123, mailer_method:, mailer_args:, open_count: 1)
      allow(described_class).to receive(:sleep)
      client.stub_responses(:batch_write_item, lambda { |context|
        if requests.count { _1[:operation_name] == :batch_write_item } == 1
          { unprocessed_items: { "email_engagement" => context.params[:request_items]["email_engagement"] } }
        else
          { unprocessed_items: {} }
        end
      })

      described_class.backfill_opens!

      expect(requests.count { _1[:operation_name] == :batch_write_item }).to eq(2)
    end
  end

  describe ".backfill_clicks!" do
    it "writes a CLICK# item and a CLICKER# marker per doc, deduping the marker across a recipient's urls" do
      clicked_at = Time.utc(2026, 2, 1, 8)
      CreatorEmailClickEvent.create!(
        installment_id: 123, mailer_method:, mailer_args:, click_url:,
        click_count: 1, click_timestamps: [clicked_at]
      )
      CreatorEmailClickEvent.create!(
        installment_id: 123, mailer_method:, mailer_args:, click_url: "https://example&#46;com/b",
        click_count: 1, click_timestamps: [clicked_at + 1.hour]
      )

      described_class.backfill_clicks!

      items = written_items(requests.sole)
      expect(items.map { _1["sk"] }).to contain_exactly(
        "CLICK##{recipient_digest}##{url_digest}",
        "CLICK##{recipient_digest}##{Digest::SHA256.hexdigest("https://example&#46;com/b")}",
        "CLICKER##{recipient_digest}"
      )
      marker = items.find { _1["sk"] == "CLICKER##{recipient_digest}" }
      expect(marker["first_click_at"]).to eq(clicked_at.iso8601(3))
      click_item = items.find { _1["sk"] == "CLICK##{recipient_digest}##{url_digest}" }
      expect(click_item).to include("click_url" => click_url, "click_count" => 1)
    end
  end

  describe ".recompute_counters!" do
    it "corrects SUMMARY and URL# counters by ADD deltas derived from item counts" do
      scan_items = [
        { "pk" => "123", "sk" => "OPEN#aaa" },
        { "pk" => "123", "sk" => "OPEN#bbb" },
        { "pk" => "123", "sk" => "CLICKER#aaa" },
        { "pk" => "123", "sk" => "CLICK#aaa#u1", "click_url" => click_url },
        { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_count" => 1 },
      ]
      client.stub_responses(:scan, { items: scan_items, last_evaluated_key: nil })

      adjustments = described_class.recompute_counters!(processes: 1)

      # open_count is off by one (2 items vs 1); click_count matches; the pair
      # count and the URL# item are missing entirely.
      expect(adjustments).to eq(3)
      updates = requests.select { _1[:operation_name] == :update_item }.map { _1[:params] }
      open_fix = updates.find { _1[:expression_attribute_names] == { "#counter" => "open_count" } }
      expect(open_fix[:key]["sk"].values.first).to eq("SUMMARY")
      expect(open_fix[:expression_attribute_values][":delta"]).to eq(n: "1")
      pair_fix = updates.find { _1[:expression_attribute_names] == { "#counter" => "click_pair_count" } }
      expect(pair_fix[:expression_attribute_values][":delta"]).to eq(n: "1")
      url_fix = updates.find { _1[:key]["sk"].values.first == "URL##{url_digest}" }
      expect(url_fix[:update_expression]).to include("if_not_exists(click_url, :click_url)")
      expect(url_fix[:expression_attribute_values][":delta"]).to eq(n: "1")
    end

    it "applies nothing when counters already match item counts" do
      scan_items = [
        { "pk" => "123", "sk" => "OPEN#aaa" },
        { "pk" => "123", "sk" => "CLICKER#aaa" },
        { "pk" => "123", "sk" => "CLICK#aaa#u1", "click_url" => click_url },
        { "pk" => "123", "sk" => "URL##{url_digest}", "click_url" => click_url, "click_count" => 1 },
        { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_count" => 1, "click_pair_count" => 1 },
      ]
      client.stub_responses(:scan, { items: scan_items, last_evaluated_key: nil })

      expect(described_class.recompute_counters!(processes: 1)).to eq(0)
      expect(requests.map { _1[:operation_name] }).to eq([:scan])
    end

    it "surfaces delta write failures" do
      scan_items = [{ "pk" => "123", "sk" => "OPEN#aaa" }]
      client.stub_responses(:scan, { items: scan_items, last_evaluated_key: nil })
      client.stub_responses(:update_item, "InternalServerError")

      expect { described_class.recompute_counters!(processes: 1) }
        .to raise_error(Aws::DynamoDB::Errors::InternalServerError)
    end

    it "flushes each installment's deltas at the pk boundary within one scan" do
      scan_items = [
        { "pk" => "123", "sk" => "OPEN#aaa" },
        { "pk" => "124", "sk" => "OPEN#bbb" },
        { "pk" => "124", "sk" => "OPEN#ccc" },
      ]
      client.stub_responses(:scan, { items: scan_items, last_evaluated_key: nil })

      expect(described_class.recompute_counters!(processes: 1)).to eq(2)

      open_fixes = requests.select { _1[:operation_name] == :update_item }.map { _1[:params] }
      expect(open_fixes.map { |u| [u[:key]["pk"].values.first, u[:expression_attribute_values][":delta"][:n]] })
        .to eq([["123", "1"], ["124", "2"]])
    end
  end

  describe ".recompute_installments_active_since!" do
    it "recomputes installments with Mongo activity in the window plus the safety margin" do
      stale = CreatorEmailOpenEvent.new(installment_id: 1, mailer_method:, mailer_args: "[1, 1]", open_count: 1)
      stale._id = BSON::ObjectId.from_time(2.days.ago)
      stale.save!
      CreatorEmailOpenEvent.create!(installment_id: 2, mailer_method:, mailer_args: "[2, 2]", open_count: 1)
      CreatorEmailClickEvent.create!(installment_id: 3, mailer_method:, mailer_args:, click_url:, click_count: 1)
      # Just before the window: covered by DRIFT_WINDOW_MARGIN.
      margin = CreatorEmailOpenEvent.new(installment_id: 4, mailer_method:, mailer_args: "[4, 4]", open_count: 1)
      margin._id = BSON::ObjectId.from_time(65.minutes.ago)
      margin.save!

      expect(described_class).to receive(:recompute_installment!).with(2)
      expect(described_class).to receive(:recompute_installment!).with(3)
      expect(described_class).to receive(:recompute_installment!).with(4)

      expect(described_class.recompute_installments_active_since!(1.hour.ago)).to eq(3)
    end
  end

  describe ".backfill_seller!" do
    it "loads only the seller's installments and recomputes their counters from the partition" do
      installment = create(:installment)
      other_installment = create(:installment)
      CreatorEmailOpenEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, open_count: 1)
      CreatorEmailOpenEvent.create!(installment_id: other_installment.id, mailer_method:, mailer_args: "[7, 7]", open_count: 1)
      pk = installment.id.to_s
      # The partition query used by the per-installment recompute sees the open
      # item but no SUMMARY, so open_count gets a +1 correction.
      client.stub_responses(:query, { items: [{ "pk" => pk, "sk" => "OPEN##{recipient_digest}" }], last_evaluated_key: nil })

      expect { described_class.backfill_seller!(installment.seller_id) }
        .to output(%r{\[1/1\] installment #{installment.id} done \(1 docs\) — 100\.0% \(1/1 docs\)}).to_stdout

      written = requests.select { _1[:operation_name] == :batch_write_item }.flat_map { written_items(_1) }
      expect(written.map { _1["pk"] }.uniq).to eq([pk])

      summary_fix = requests.select { _1[:operation_name] == :update_item }.map { _1[:params] }.sole
      expect(summary_fix[:key]["sk"].values.first).to eq("SUMMARY")
      expect(summary_fix[:expression_attribute_names]).to eq("#counter" => "open_count")
      expect(summary_fix[:expression_attribute_values][":delta"]).to eq(n: "1")
    end
  end

  describe ".backfill_installment!" do
    it "loads a single installment's docs and recomputes its counters, leaving siblings alone" do
      installment = create(:installment)
      sibling = create(:installment)
      CreatorEmailOpenEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, open_count: 1)
      CreatorEmailClickEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, click_url:, click_count: 1)
      CreatorEmailOpenEvent.create!(installment_id: sibling.id, mailer_method:, mailer_args: "[7, 7]", open_count: 1)
      client.stub_responses(:query, { items: [], last_evaluated_key: nil })

      docs = described_class.backfill_installment!(installment.id)

      expect(docs).to eq(2)
      written = requests.select { _1[:operation_name] == :batch_write_item }.flat_map { written_items(_1) }
      expect(written.map { _1["pk"] }.uniq).to eq([installment.id.to_s])
      expect(written.map { _1["sk"] }).to contain_exactly(
        "OPEN##{recipient_digest}",
        "CLICK##{recipient_digest}##{url_digest}",
        "CLICKER##{recipient_digest}"
      )
    end
  end

  describe ".verify_seller!" do
    it "reports nothing when DynamoDB matches the Mongo documents" do
      installment = create(:installment)
      CreatorEmailOpenEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, open_count: 2)
      CreatorEmailClickEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, click_url:, click_count: 1)
      client.stub_responses(:get_item, { item: { "pk" => installment.id.to_s, "sk" => "SUMMARY", "open_count" => 1, "click_count" => 1, "click_pair_count" => 1 } })
      client.stub_responses(:query, { items: [{ "pk" => installment.id.to_s, "sk" => "URL##{url_digest}", "click_url" => click_url, "click_count" => 1 }], last_evaluated_key: nil })

      expect(described_class.verify_seller!(installment.seller_id)).to eq([])
    end

    it "reports installments where DynamoDB disagrees with the document-derived counts" do
      installment = create(:installment)
      CreatorEmailClickSummary.create!(installment_id: installment.id, total_unique_clicks: 9, urls: {})
      CreatorEmailOpenEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, open_count: 1)
      CreatorEmailClickEvent.create!(installment_id: installment.id, mailer_method:, mailer_args:, click_url:, click_count: 1)
      client.stub_responses(:get_item, { item: { "pk" => installment.id.to_s, "sk" => "SUMMARY", "open_count" => 1, "click_count" => 2, "click_pair_count" => 1 } })
      client.stub_responses(:query, { items: [{ "pk" => installment.id.to_s, "sk" => "URL##{url_digest}", "click_url" => click_url, "click_count" => 1 }], last_evaluated_key: nil })

      mismatch = described_class.verify_seller!(installment.seller_id).sole
      expect(mismatch[:dynamo]).to eq(opens: 1, clicks: 2, pairs: 1, urls: { click_url => 1 })
      expect(mismatch[:mongo_docs]).to eq(opens: 1, clicks: 1, pairs: 1, urls: { click_url => 1 })
      expect(mismatch[:mongo_stored_clicks]).to eq(9)
    end
  end

  describe ".verify!" do
    it "reports installments whose DynamoDB counters disagree with the Mongo documents" do
      CreatorEmailClickSummary.create!(installment_id: 123, total_unique_clicks: 5, urls: {})
      CreatorEmailOpenEvent.create!(installment_id: 123, mailer_method:, mailer_args:, open_count: 1)
      CreatorEmailClickEvent.create!(installment_id: 123, mailer_method:, mailer_args:, click_url:, click_count: 1)
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_pair_count" => 3 } })

      mismatches = described_class.verify!(sample_size: 10)

      expect(mismatches.sole).to eq(
        installment_id: 123,
        expected: { opens: 1, pairs: 1 },
        actual: { opens: 1, pairs: 3 },
        mongo_stored_clicks: 5
      )
    end

    it "does not enforce Mongo's stored click counter when the documents match" do
      CreatorEmailClickSummary.create!(installment_id: 123, total_unique_clicks: 5, urls: {})
      CreatorEmailOpenEvent.create!(installment_id: 123, mailer_method:, mailer_args:, open_count: 1)
      CreatorEmailClickEvent.create!(installment_id: 123, mailer_method:, mailer_args:, click_url:, click_count: 1)
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_pair_count" => 1 } })

      expect(described_class.verify!(sample_size: 10)).to eq([])
    end

    it "expects the deduplicated pair count when Mongo holds duplicate click docs" do
      CreatorEmailClickSummary.create!(installment_id: 123, total_unique_clicks: 2, urls: {})
      CreatorEmailOpenEvent.create!(installment_id: 123, mailer_method:, mailer_args:, open_count: 1)
      # Two docs for the same recipient+url pair: possible in production because
      # the unique click_index was never built there.
      2.times { CreatorEmailClickEvent.create!(installment_id: 123, mailer_method:, mailer_args:, click_url:, click_count: 1) }
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_pair_count" => 1 } })

      expect(described_class.verify!(sample_size: 10)).to eq([])
    end
  end
end
