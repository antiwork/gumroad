# frozen_string_literal: true

describe Onetime::BackfillEmailEngagementDynamoTable do
  let(:client) { Aws::DynamoDB::Client.new(stub_responses: true) }
  let(:mailer_method) { "CreatorContactingCustomersMailer.purchase_installment" }
  let(:mailer_args) { "[123, 456]" }
  let(:recipient_digest) { Digest::SHA256.hexdigest("#{mailer_method}\n#{mailer_args}") }
  let(:click_url) { "https://example&#46;com/a" }
  let(:url_digest) { Digest::SHA256.hexdigest(click_url) }

  before do
    EmailEngagementDynamoStore.client = client
    $redis.del(described_class::OPENS_CURSOR_KEY, described_class::CLICKS_CURSOR_KEY)
  end

  after do
    EmailEngagementDynamoStore.client = nil
    $redis.del(described_class::OPENS_CURSOR_KEY, described_class::CLICKS_CURSOR_KEY)
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

      adjustments = described_class.recompute_counters!

      # open_count is off by one (2 items vs 1); click_count matches; URL# item is missing entirely.
      expect(adjustments).to eq(2)
      updates = requests.select { _1[:operation_name] == :update_item }.map { _1[:params] }
      open_fix = updates.find { _1[:expression_attribute_names] == { "#counter" => "open_count" } }
      expect(open_fix[:key]["sk"].values.first).to eq("SUMMARY")
      expect(open_fix[:expression_attribute_values][":delta"]).to eq(n: "1")
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
        { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_count" => 1 },
      ]
      client.stub_responses(:scan, { items: scan_items, last_evaluated_key: nil })

      expect(described_class.recompute_counters!).to eq(0)
      expect(requests.map { _1[:operation_name] }).to eq([:scan])
    end
  end

  describe ".verify!" do
    it "reports installments whose DynamoDB counters disagree with Mongo" do
      CreatorEmailClickSummary.create!(installment_id: 123, total_unique_clicks: 5, urls: {})
      CreatorEmailOpenEvent.create!(installment_id: 123, mailer_method:, mailer_args:, open_count: 1)
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "SUMMARY", "open_count" => 1, "click_count" => 4 } })

      mismatches = described_class.verify!(sample_size: 10)

      expect(mismatches.sole).to eq(
        installment_id: 123,
        expected: { clicks: 5, opens: 1 },
        actual: { clicks: 4, opens: 1 }
      )
    end
  end
end
