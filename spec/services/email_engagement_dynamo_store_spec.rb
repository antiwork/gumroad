# frozen_string_literal: true

describe EmailEngagementDynamoStore do
  let(:client) { Aws::DynamoDB::Client.new(stub_responses: true) }
  let(:mailer_method) { "CreatorContactingCustomersMailer.purchase_installment" }
  let(:mailer_args) { "[123, 456]" }
  let(:recipient_digest) { Digest::SHA256.hexdigest("#{mailer_method}\n#{mailer_args}") }
  let(:click_url) { "https://www&#46;gumroad&#46;com/checkout" }
  let(:url_digest) { Digest::SHA256.hexdigest(click_url) }

  before do
    described_class.client = client
  end

  after do
    described_class.client = nil
  end

  def requests
    client.api_requests
  end

  # api_requests records attribute values in wire format ({ n: "1" }, { s: "abc" });
  # convert them back to plain Ruby values for assertions.
  def plain(attribute_value)
    type, value = attribute_value.first
    type == :n ? Integer(value) : value
  end

  def plain_hash(hash)
    hash.transform_values { plain(_1) }
  end

  def stub_transact(*steps)
    i = 0
    client.stub_responses(:transact_write_items, lambda do |_context|
      step = steps[i] || steps.last
      i += 1
      case step
      when :ok
        {}
      when :conditional
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [ConditionalCheckFailed, None, None]"
        )
      when :conflict
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [TransactionConflict, None, None]"
        )
      else
        step
      end
    end)
  end

  describe ".record_open" do
    it "writes in production without a feature flag" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items])
    end

    it "upserts the open item and increments the summary open count on a recipient's first open" do
      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items])

      items = requests.first[:params][:transact_items]
      open_put = items.first[:put]
      expect(open_put[:table_name]).to eq(described_class.table_name)
      expect(plain_hash(open_put[:item].slice("pk", "sk"))).to eq("pk" => "123", "sk" => "OPEN##{recipient_digest}")
      expect(plain(open_put[:item]["mailer_method"])).to eq(mailer_method)
      expect(plain(open_put[:item]["mailer_args"])).to eq(mailer_args)
      expect(plain(open_put[:item]["open_count"])).to eq(1)
      expect(open_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      summary_update = items.last[:update]
      expect(plain_hash(summary_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_update[:update_expression]).to eq("ADD #counter :one")
      expect(summary_update[:expression_attribute_names]).to eq("#counter" => "open_count")
    end

    it "does not touch the summary when the recipient has opened before" do
      stub_transact(:conditional)

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items, :update_item])
      expect(plain_hash(requests.last[:params][:key])).to eq("pk" => "123", "sk" => "OPEN##{recipient_digest}")
      expect(requests.last[:params][:update_expression]).to include("ADD open_count :one")
      expect(requests.last[:params][:update_expression]).to include("last_open_at = :now")
    end

    it "raises when DynamoDB fails so Sidekiq can retry" do
      client.stub_responses(:transact_write_items, "InternalServerError")

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.to raise_error(Aws::Errors::ServiceError)
    end
  end

  describe ".record_click" do
    it "writes in production without a feature flag" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests).not_to be_empty
    end

    it "records a first-ever click with the url total, the pair count, the clicker marker, the summary click count, and a compensating open" do
      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items, :transact_write_items, :transact_write_items])

      click_items = requests[0][:params][:transact_items]
      click_put = click_items[0][:put]
      expect(plain(click_put[:item]["pk"])).to eq("123")
      expect(plain(click_put[:item]["sk"])).to eq("CLICK##{recipient_digest}##{url_digest}")
      expect(plain(click_put[:item]["click_url"])).to eq(click_url)
      expect(plain(click_put[:item]["click_count"])).to eq(1)
      expect(click_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      url_update = click_items[1][:update]
      expect(plain_hash(url_update[:key])).to eq("pk" => "123", "sk" => "URL##{url_digest}")
      expect(url_update[:update_expression]).to eq("ADD click_count :one SET click_url = :click_url")
      expect(plain(url_update[:expression_attribute_values][":click_url"])).to eq(click_url)

      pair_update = click_items[2][:update]
      expect(plain_hash(pair_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(pair_update[:expression_attribute_names]).to eq("#counter" => "click_pair_count")

      clicker_items = requests[1][:params][:transact_items]
      marker_put = clicker_items[0][:put]
      expect(plain(marker_put[:item]["pk"])).to eq("123")
      expect(plain(marker_put[:item]["sk"])).to eq("CLICKER##{recipient_digest}")
      expect(plain(marker_put[:item]["mailer_args"])).to eq(mailer_args)
      expect(marker_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      summary_click_update = clicker_items[1][:update]
      expect(plain_hash(summary_click_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_click_update[:expression_attribute_names]).to eq("#counter" => "click_count")

      open_items = requests[2][:params][:transact_items]
      open_put = open_items[0][:put]
      expect(plain(open_put[:item]["pk"])).to eq("123")
      expect(plain(open_put[:item]["sk"])).to eq("OPEN##{recipient_digest}")
      expect(plain(open_put[:item]["open_count"])).to eq(1)
      expect(open_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      summary_open_update = open_items[1][:update]
      expect(plain_hash(summary_open_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_open_update[:expression_attribute_names]).to eq("#counter" => "open_count")
    end

    it "counts the pair but not the summary click count when the recipient has clicked another url before" do
      stub_transact(:ok, :conditional, :conditional)

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items, :transact_write_items, :transact_write_items])
      expect(plain(requests[0][:params][:transact_items][0][:put][:item]["sk"])).to eq("CLICK##{recipient_digest}##{url_digest}")
      expect(plain_hash(requests[0][:params][:transact_items][1][:update][:key])).to eq("pk" => "123", "sk" => "URL##{url_digest}")
      expect(requests[0][:params][:transact_items][2][:update][:expression_attribute_names]).to eq("#counter" => "click_pair_count")
      expect(plain(requests[1][:params][:transact_items][0][:put][:item]["sk"])).to eq("CLICKER##{recipient_digest}")
    end

    it "counts nothing on a repeat click of the same url by the same recipient" do
      stub_transact(:conditional)

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items, :transact_write_items, :transact_write_items])
      expect(requests).to all(satisfy { |req| req[:operation_name] == :transact_write_items })
    end

    it "still writes clicker and open counters when a retry finds the click item already committed" do
      stub_transact(:conditional, :ok, :ok)

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:transact_write_items, :transact_write_items, :transact_write_items])
      expect(plain(requests[1][:params][:transact_items][0][:put][:item]["sk"])).to eq("CLICKER##{recipient_digest}")
      expect(requests[1][:params][:transact_items][1][:update][:expression_attribute_names]).to eq("#counter" => "click_count")
      expect(plain(requests[2][:params][:transact_items][0][:put][:item]["sk"])).to eq("OPEN##{recipient_digest}")
    end

    it "raises when DynamoDB fails so Sidekiq can retry" do
      client.stub_responses(:transact_write_items, "ProvisionedThroughputExceededException")

      expect do
        described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)
      end.to raise_error(Aws::Errors::ServiceError)
    end

    it "raises retryable transaction cancellations that are not conditional duplicates" do
      stub_transact(:conflict)

      expect do
        described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)
      end.to raise_error(Aws::DynamoDB::Errors::TransactionCanceledException)
    end
  end

  describe ".client" do
    it "defaults to the regional DynamoDB endpoint when DYNAMODB_ENDPOINT is unset" do
      described_class.client = nil
      endpoint_was = ENV.delete("DYNAMODB_ENDPOINT")
      expect(described_class.client.config.endpoint.to_s).to eq("https://dynamodb.#{AWS_DEFAULT_REGION}.amazonaws.com")
    ensure
      ENV["DYNAMODB_ENDPOINT"] = endpoint_was if endpoint_was
    end

    it "honors DYNAMODB_ENDPOINT when set" do
      described_class.client = nil
      endpoint_was = ENV["DYNAMODB_ENDPOINT"]
      ENV["DYNAMODB_ENDPOINT"] = "http://localhost:8123"
      expect(described_class.client.config.endpoint.to_s).to eq("http://localhost:8123")
    ensure
      endpoint_was.nil? ? ENV.delete("DYNAMODB_ENDPOINT") : ENV["DYNAMODB_ENDPOINT"] = endpoint_was
    end
  end

  describe ".table_name" do
    it "prepends DYNAMODB_TABLE_PREFIX when set" do
      original = ENV["DYNAMODB_TABLE_PREFIX"]
      ENV.delete("DYNAMODB_TABLE_PREFIX")
      expect(described_class.table_name).to eq("email_engagement")

      ENV["DYNAMODB_TABLE_PREFIX"] = "lane1_"
      expect(described_class.table_name).to eq("lane1_email_engagement")
    ensure
      original.nil? ? ENV.delete("DYNAMODB_TABLE_PREFIX") : ENV["DYNAMODB_TABLE_PREFIX"] = original
    end

    it "defaults to the Terraform-owned per-environment table in production and staging" do
      original = ENV["DYNAMODB_TABLE_PREFIX"]
      ENV.delete("DYNAMODB_TABLE_PREFIX")
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      expect(described_class.table_name).to eq("production-email_engagement")

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      expect(described_class.table_name).to eq("staging-email_engagement")
    ensure
      original.nil? ? ENV.delete("DYNAMODB_TABLE_PREFIX") : ENV["DYNAMODB_TABLE_PREFIX"] = original
    end

    it "lets DYNAMODB_TABLE_PREFIX override the environment default for branch apps" do
      original = ENV["DYNAMODB_TABLE_PREFIX"]
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      ENV["DYNAMODB_TABLE_PREFIX"] = "branchapp-foo-"
      expect(described_class.table_name).to eq("branchapp-foo-email_engagement")
    ensure
      original.nil? ? ENV.delete("DYNAMODB_TABLE_PREFIX") : ENV["DYNAMODB_TABLE_PREFIX"] = original
    end
  end

  describe ".partition_key" do
    it "stringifies the installment id" do
      expect(described_class.partition_key(123)).to eq("123")
      expect(described_class.partition_key("123")).to eq("123")
    end
  end

  describe ".create_table!" do
    it "creates the on-demand table with the generic pk/sk string key schema" do
      described_class.create_table!

      request = requests.sole
      expect(request[:operation_name]).to eq(:create_table)
      expect(request[:params][:table_name]).to eq(described_class.table_name)
      expect(request[:params][:billing_mode]).to eq("PAY_PER_REQUEST")
      expect(request[:params][:attribute_definitions]).to eq(
        [
          { attribute_name: "pk", attribute_type: "S" },
          { attribute_name: "sk", attribute_type: "S" },
        ]
      )
      expect(request[:params][:key_schema]).to eq(
        [
          { attribute_name: "pk", key_type: "HASH" },
          { attribute_name: "sk", key_type: "RANGE" },
        ]
      )
    end
  end

  describe ".summary" do
    it "returns zeroed counters when the item is missing" do
      client.stub_responses(:get_item, { item: nil })

      expect(described_class.summary(123)).to eq(open_count: 0, click_count: 0, click_pair_count: 0)
    end

    it "reads open and click-pair counters from SUMMARY" do
      client.stub_responses(:get_item, { item: { "open_count" => 10, "click_count" => 7, "click_pair_count" => 9 } })

      expect(described_class.summary(123)).to eq(open_count: 10, click_count: 7, click_pair_count: 9)
    end
  end

  describe ".summaries" do
    it "batch-gets SUMMARY items and fills zeros for missing partitions" do
      client.stub_responses(
        :batch_get_item,
        {
          responses: {
            described_class.table_name => [{ "pk" => "123", "open_count" => 10, "click_pair_count" => 4 }],
          },
        }
      )

      result = described_class.summaries([123, 456])
      expect(result[123]).to eq(open_count: 10, click_count: 0, click_pair_count: 4)
      expect(result[456]).to eq(open_count: 0, click_count: 0, click_pair_count: 0)
    end

    it "retries unprocessed keys instead of zero-filling them" do
      allow(described_class).to receive(:sleep)
      client.stub_responses(
        :batch_get_item,
        [
          {
            responses: { described_class.table_name => [] },
            unprocessed_keys: {
              described_class.table_name => { keys: [{ "pk" => "123", "sk" => "SUMMARY" }] },
            },
          },
          {
            responses: {
              described_class.table_name => [{ "pk" => "123", "open_count" => 10, "click_pair_count" => 4 }],
            },
          },
        ]
      )

      result = described_class.summaries([123])
      expect(result[123]).to eq(open_count: 10, click_count: 0, click_pair_count: 4)
      expect(requests.map { _1[:operation_name] }).to eq([:batch_get_item, :batch_get_item])
    end

    it "raises when unprocessed keys remain after retries" do
      allow(described_class).to receive(:sleep)
      client.stub_responses(
        :batch_get_item,
        {
          responses: { described_class.table_name => [] },
          unprocessed_keys: {
            described_class.table_name => { keys: [{ "pk" => "123", "sk" => "SUMMARY" }] },
          },
        }
      )

      expect { described_class.summaries([123]) }.to raise_error(/Unprocessed keys remain/)
    end
  end

  describe ".url_click_counts" do
    it "strips protocol and www from URL# click_url values" do
      client.stub_responses(
        :query,
        {
          items: [
            { "click_url" => "https://www.gumroad.com/l/a", "click_count" => 5 },
            { "click_url" => "https://example.com", "click_count" => 2 },
          ],
        }
      )

      expect(described_class.url_click_counts(123)).to eq(
        "gumroad.com/l/a" => 5,
        "example.com" => 2,
      )
    end
  end
end
