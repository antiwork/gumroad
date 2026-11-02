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
    described_class.deadline_client = client
    allow(described_class).to receive(:sleep)
  end

  after do
    described_class.client = nil
    described_class.deadline_client = nil
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
      when :conditional_and_conflict
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [ConditionalCheckFailed, TransactionConflict]"
        )
      when :conflict_and_throttle
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [TransactionConflict, ProvisionedThroughputExceeded]"
        )
      when :throttle
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [None, ThrottlingError]"
        )
      when :conditional_and_throttle
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [ConditionalCheckFailed, ThrottlingError]"
        )
      when :validation
        raise Aws::DynamoDB::Errors::TransactionCanceledException.new(
          nil,
          "Transaction cancelled, please refer cancellation reasons for specific reasons [None, ValidationError]"
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

    it "raises a transaction conflict only after exhausting the in-process attempts" do
      stub_transact(:conflict)

      expect do
        described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)
      end.to raise_error(Aws::DynamoDB::Errors::TransactionCanceledException)

      expect(requests.count { _1[:operation_name] == :transact_write_items })
        .to eq(EmailEngagementDynamoStore::TRANSACT_CONFLICT_MAX_ATTEMPTS)
    end
  end

  describe "SUMMARY item contention" do
    it "retries a conflicted transaction in place rather than failing the event" do
      stub_transact(:conflict, :ok)

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.not_to raise_error

      expect(requests.map { _1[:operation_name] }).to eq(%i[transact_write_items transact_write_items])
    end

    it "settles a duplicate at once when a conflict cancels the same transaction" do
      stub_transact(:conditional_and_conflict)

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      # No retry: the repeat-open update bumps last_open_at rather than the summary.
      expect(described_class).not_to have_received(:sleep)
      expect(requests.map { _1[:operation_name] }).to eq(%i[transact_write_items update_item])
    end

    it "backs off between attempts so contending writers do not line up again" do
      stub_transact(:conflict, :ok)

      expect(described_class).to receive(:sleep).once.with(a_value_between(0, EmailEngagementDynamoStore::TRANSACT_CONFLICT_BACKOFF))

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
    end

    it "leaves a request-level throughput error to the SDK's retries and the job's" do
      client.stub_responses(:transact_write_items, "ProvisionedThroughputExceededException")

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.to raise_error(Aws::Errors::ServiceError)

      expect(requests.count { _1[:operation_name] == :transact_write_items }).to eq(1)
    end

    it "retries a throttled transaction in place with the longer throttle backoff" do
      stub_transact(:throttle, :throttle, :ok)
      allow(described_class).to receive(:rand).and_return(0.5)

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.not_to raise_error

      backoff = EmailEngagementDynamoStore::TRANSACT_THROTTLE_BACKOFF
      expect(described_class).to have_received(:sleep).with(backoff * 0.5).ordered
      expect(described_class).to have_received(:sleep).with(backoff * 0.5 * 2).ordered
      expect(requests.count { _1[:operation_name] == :transact_write_items }).to eq(3)
    end

    it "gives a conflict-plus-throttle cancellation the throttle attempts" do
      stub_transact(:conflict_and_throttle)

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.to raise_error(Aws::DynamoDB::Errors::TransactionCanceledException)

      expect(requests.count { _1[:operation_name] == :transact_write_items })
        .to eq(EmailEngagementDynamoStore::TRANSACT_THROTTLE_MAX_ATTEMPTS)
    end

    it "keeps the throttle attempts when a conflict follows a throttle" do
      stub_transact(:throttle, :throttle, :conflict, :ok)

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.not_to raise_error

      expect(requests.count { _1[:operation_name] == :transact_write_items }).to eq(4)
    end

    it "settles a throttled duplicate at once without retrying" do
      stub_transact(:conditional_and_throttle)

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(described_class).not_to have_received(:sleep)
      expect(requests.map { _1[:operation_name] }).to eq(%i[transact_write_items update_item])
    end

    it "raises a throttle only after exhausting the throttle attempts" do
      stub_transact(:throttle)

      expect do
        described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)
      end.to raise_error(Aws::DynamoDB::Errors::TransactionCanceledException)

      expect(requests.count { _1[:operation_name] == :transact_write_items })
        .to eq(EmailEngagementDynamoStore::TRANSACT_THROTTLE_MAX_ATTEMPTS)
    end

    it "raises without retrying a cancellation a retry cannot clear" do
      stub_transact(:validation)

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.to raise_error(Aws::DynamoDB::Errors::TransactionCanceledException)

      expect(requests.count { _1[:operation_name] == :transact_write_items }).to eq(1)
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
    let(:open_time_index) do
      {
        index_name: "pk-first_open_at-index",
        key_schema: [
          { attribute_name: "pk", key_type: "HASH" },
          { attribute_name: "first_open_at", key_type: "RANGE" },
        ],
        projection: { projection_type: "INCLUDE", non_key_attributes: ["mailer_method", "mailer_args"] },
      }
    end

    # One DescribeTable response per status, in order; nil is a table without the open-time index.
    def stub_index_statuses(*statuses)
      client.stub_responses(:describe_table, statuses.map do |status|
        indexes = status ? [{ index_name: "pk-first_open_at-index", index_status: status }] : []
        { table: { table_name: described_class.table_name, global_secondary_indexes: indexes } }
      end)
    end

    def operations
      requests.map { _1[:operation_name] }
    end

    it "creates the on-demand table with the generic pk/sk string key schema and the open-time index" do
      stub_index_statuses("ACTIVE")

      described_class.create_table!

      request = requests.first
      expect(request[:operation_name]).to eq(:create_table)
      expect(request[:params][:table_name]).to eq(described_class.table_name)
      expect(request[:params][:billing_mode]).to eq("PAY_PER_REQUEST")
      expect(request[:params][:attribute_definitions]).to eq(
        [
          { attribute_name: "pk", attribute_type: "S" },
          { attribute_name: "sk", attribute_type: "S" },
          { attribute_name: "first_open_at", attribute_type: "S" },
        ]
      )
      expect(request[:params][:key_schema]).to eq(
        [
          { attribute_name: "pk", key_type: "HASH" },
          { attribute_name: "sk", key_type: "RANGE" },
        ]
      )
      expect(request[:params][:global_secondary_indexes]).to eq([open_time_index])
      expect(operations).to eq([:create_table, :describe_table])
    end

    it "returns a new table only once its open-time index is ACTIVE" do
      stub_index_statuses("CREATING", "CREATING", "ACTIVE")

      described_class.create_table!

      expect(operations).to eq([:create_table, :describe_table, :describe_table, :describe_table])
      expect(described_class).to have_received(:sleep).with(described_class::OPEN_TIME_INDEX_POLL_SECONDS).twice
    end

    context "when the table already exists" do
      before { client.stub_responses(:create_table, "ResourceInUseException") }

      it "adds the open-time index to a table that predates it and re-raises for the callers that rescue it once the index is ACTIVE" do
        stub_index_statuses(nil, "CREATING", "ACTIVE")

        expect { described_class.create_table! }.to raise_error(Aws::DynamoDB::Errors::ResourceInUseException)

        update = requests.find { _1[:operation_name] == :update_table }
        expect(update[:params][:global_secondary_index_updates]).to eq([{ create: open_time_index }])
        expect(update[:params][:attribute_definitions]).to eq(
          [
            { attribute_name: "pk", attribute_type: "S" },
            { attribute_name: "first_open_at", attribute_type: "S" },
          ]
        )
        expect(operations).to eq([:create_table, :describe_table, :update_table, :describe_table, :describe_table])
      end

      it "waits for the index when another setup's UpdateTable is adding it at the same time" do
        stub_index_statuses(nil, "CREATING", "ACTIVE")
        client.stub_responses(:update_table, "ResourceInUseException")

        expect { described_class.create_table! }.to raise_error(Aws::DynamoDB::Errors::ResourceInUseException)

        expect(operations).to eq([:create_table, :describe_table, :update_table, :describe_table, :describe_table])
      end

      it "leaves a table whose index is ACTIVE alone" do
        stub_index_statuses("ACTIVE")

        expect { described_class.create_table! }.to raise_error(Aws::DynamoDB::Errors::ResourceInUseException)

        expect(operations).to eq([:create_table, :describe_table])
        expect(described_class).not_to have_received(:sleep)
      end

      it "waits for an index that is still building without adding it again" do
        stub_index_statuses("CREATING", "CREATING", "ACTIVE")

        expect { described_class.create_table! }.to raise_error(Aws::DynamoDB::Errors::ResourceInUseException)

        expect(operations).to eq([:create_table, :describe_table, :describe_table, :describe_table])
      end

      it "gives up with an error the setup callers do not rescue when the index stays CREATING past the bound" do
        stub_index_statuses("CREATING")

        expect { described_class.create_table! }.to raise_error(
          described_class::OpenTimeIndexNotReady,
          "pk-first_open_at-index on #{described_class.table_name} is not ACTIVE after 600s; run setup again once it is"
        )

        polls = described_class::OPEN_TIME_INDEX_READY_TIMEOUT_SECONDS / described_class::OPEN_TIME_INDEX_POLL_SECONDS
        expect(described_class).to have_received(:sleep).exactly(polls).times
        expect(operations.count(:describe_table)).to eq(polls + 1)
      end
    end

    # DynamoDB Local reports an index it is adding as CREATING for a moment, like AWS does for longer.
    context "against DynamoDB Local" do
      let(:table_name) { "test_upgrade_#{SecureRandom.hex(4)}_email_engagement" }
      let(:installment_id) { 10**12 + SecureRandom.random_number(10**9) }

      before do
        described_class.client = nil
        allow(described_class).to receive(:table_name).and_return(table_name)
        allow(described_class).to receive(:sleep).and_call_original
        described_class.client.create_table(
          table_name:,
          attribute_definitions: [{ attribute_name: "pk", attribute_type: "S" }, { attribute_name: "sk", attribute_type: "S" }],
          key_schema: [{ attribute_name: "pk", key_type: "HASH" }, { attribute_name: "sk", key_type: "RANGE" }],
          billing_mode: "PAY_PER_REQUEST"
        )
      end

      after { described_class.client.delete_table(table_name:) }

      it "adds the index to a table that predates it and hands it back queryable" do
        described_class.record_open(installment_id:, mailer_method:, mailer_args: "[1, #{installment_id}]")

        expect { described_class.create_table! }.to raise_error(Aws::DynamoDB::Errors::ResourceInUseException)

        indexes = described_class.client.describe_table(table_name:).table.global_secondary_indexes
        expect(indexes.map { [_1.index_name, _1.index_status] }).to eq([["pk-first_open_at-index", "ACTIVE"]])
        expect(described_class.purchase_open_records(installment_id, opened_after: 1.minute.ago, opened_before: 1.minute.from_now).map { _1[:purchase_id] }).to eq([1])
      end
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

    it "sums the counts of stored URLs that share a display form" do
      client.stub_responses(
        :query,
        {
          items: [
            { "click_url" => "https://example.com/a", "click_count" => 3 },
            { "click_url" => "http://www&#46;example&#46;com/a", "click_count" => 4 },
            { "click_url" => "https://gumroad.com", "click_count" => 1 },
          ],
        }
      )

      expect(described_class.url_click_counts(123)).to eq(
        "example.com/a" => 7,
        "gumroad.com" => 1,
      )
    end
  end

  describe ".clicked_recipient_purchase_ids" do
    let(:purchase_click) { { "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[456, 123]" } }

    it "returns the buyer behind each purchase installment click" do
      client.stub_responses(
        :query,
        {
          items: [
            purchase_click.merge("sk" => "CLICKER#aaa"),
            { "sk" => "CLICKER#bbb", "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[789, 123]" },
          ],
        }
      )

      expect(described_class.clicked_recipient_purchase_ids(123)).to eq([456, 789])
    end

    it "reads the clicker items of that installment only" do
      client.stub_responses(:query, { items: [] })

      described_class.clicked_recipient_purchase_ids(123)

      expect(requests.last[:params]).to include(
        table_name: described_class.table_name,
        key_condition_expression: "pk = :pk AND begins_with(sk, :prefix)",
        expression_attribute_values: { ":pk" => { s: "123" }, ":prefix" => { s: "CLICKER#" } }
      )
    end

    it "skips follower and affiliate clicks, whose args carry that record's id" do
      client.stub_responses(
        :query,
        {
          items: [
            { "sk" => "CLICKER#aaa", "mailer_method" => "CreatorContactingCustomersMailer.follower_installment", "mailer_args" => "[12, 123]" },
            { "sk" => "CLICKER#bbb", "mailer_method" => "CreatorContactingCustomersMailer.direct_affiliate_installment", "mailer_args" => "[34, 123]" },
          ],
        }
      )

      expect(described_class.clicked_recipient_purchase_ids(123)).to eq([])
    end

    it "returns a buyer once, however many links they clicked" do
      client.stub_responses(:query, { items: [purchase_click.merge("sk" => "CLICK#aaa"), purchase_click.merge("sk" => "CLICK#bbb")] })

      expect(described_class.clicked_recipient_purchase_ids(123)).to eq([456])
    end

    it "pages through the partition" do
      pages = [
        { items: [purchase_click.merge("sk" => "CLICKER#aaa")], last_evaluated_key: { "pk" => "123", "sk" => "CLICKER#aaa" } },
        { items: [{ "sk" => "CLICKER#bbb", "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[789, 123]" }] },
      ]
      page_index = 0
      client.stub_responses(:query, lambda do |_context|
        page = pages[page_index] || pages.last
        page_index += 1
        page
      end)

      expect(described_class.clicked_recipient_purchase_ids(123)).to eq([456, 789])
      expect(requests.map { _1[:params][:exclusive_start_key] }).to eq([nil, { "pk" => { s: "123" }, "sk" => { s: "CLICKER#aaa" } }])
    end
  end

  describe ".opened_recipient_ids" do
    let(:opened_purchase) { { "sk" => "OPEN#aaa", "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[456, 123]" } }

    it "groups the openers by the record the send addressed them as" do
      client.stub_responses(
        :query,
        {
          items: [
            opened_purchase,
            { "sk" => "OPEN#bbb", "mailer_method" => "CreatorContactingCustomersMailer.follower_installment", "mailer_args" => "[12, 123]" },
            { "sk" => "OPEN#ccc", "mailer_method" => "CreatorContactingCustomersMailer.direct_affiliate_installment", "mailer_args" => "[34, 123]" },
          ],
        }
      )

      expect(described_class.opened_recipient_ids(123)).to eq(purchase_ids: [456], follower_ids: [12], affiliate_ids: [34])
    end

    it "reads the open items of that installment only" do
      client.stub_responses(:query, { items: [] })

      described_class.opened_recipient_ids(123)

      expect(requests.last[:params]).to include(
        table_name: described_class.table_name,
        key_condition_expression: "pk = :pk AND begins_with(sk, :prefix)",
        expression_attribute_values: { ":pk" => { s: "123" }, ":prefix" => { s: "OPEN#" } }
      )
    end

    it "returns a recipient once, however many times they opened" do
      client.stub_responses(:query, { items: [opened_purchase, opened_purchase.merge("sk" => "OPEN#zzz")] })

      expect(described_class.opened_recipient_ids(123)).to eq(purchase_ids: [456], follower_ids: [], affiliate_ids: [])
    end

    it "ignores an item whose args carry no id" do
      client.stub_responses(:query, { items: [{ "sk" => "OPEN#aaa", "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment" }] })

      expect(described_class.opened_recipient_ids(123)).to eq(purchase_ids: [], follower_ids: [], affiliate_ids: [])
    end

    it "stops the walk when the caller's deadline has already passed" do
      client.stub_responses(:query, { items: [opened_purchase] })

      expect do
        described_class.opened_recipient_ids(123, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)
      end.to raise_error(EmailEngagementDynamoStore::ScanBudgetExceeded)
    end

    it "gives up on a page that times out inside the caller's deadline" do
      client.stub_responses(:query, Seahorse::Client::NetworkingError.new(Net::ReadTimeout.new))

      expect do
        described_class.opened_recipient_ids(123, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
      end.to raise_error(EmailEngagementDynamoStore::ScanBudgetExceeded)
    end

    it "gives up on a throttled or failed page inside the caller's deadline, but raises it without one" do
      client.stub_responses(:query, ["ProvisionedThroughputExceededException", "InternalServerError", "InternalServerError"])

      expect do
        described_class.opened_recipient_ids(123, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
      end.to raise_error(EmailEngagementDynamoStore::ScanBudgetExceeded)
      expect do
        described_class.opened_recipient_ids(123, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
      end.to raise_error(EmailEngagementDynamoStore::ScanBudgetExceeded)
      expect { described_class.opened_recipient_ids(123) }.to raise_error(Aws::DynamoDB::Errors::InternalServerError)
    end

    it "reads with a short, unretried client only when the caller has a deadline" do
      described_class.deadline_client = nil
      bounded_client = described_class.deadline_client

      expect(bounded_client.config).to have_attributes(http_read_timeout: 0.3, http_open_timeout: 0.3, retry_limit: 0, max_attempts: 1)
      allow(bounded_client).to receive(:query).and_return(double(items: [opened_purchase], last_evaluated_key: nil))

      expect(described_class.opened_recipient_ids(123, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)[:purchase_ids]).to eq([456])
      expect(described_class.opened_recipient_ids(123)[:purchase_ids]).to eq([])
      expect(bounded_client).to have_received(:query).once
    end
  end

  describe ".opened_recipient_purchase_ids" do
    it "returns the buyer behind each purchase installment open, once, from the OPEN items only" do
      open_item = { "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[456, 123]" }
      client.stub_responses(
        :query,
        {
          items: [
            open_item.merge("sk" => "OPEN#aaa"),
            open_item.merge("sk" => "OPEN#bbb"),
            { "sk" => "OPEN#ccc", "mailer_method" => "CreatorContactingCustomersMailer.follower_installment", "mailer_args" => "[12, 123]" },
          ],
        }
      )

      expect(described_class.opened_recipient_purchase_ids(123)).to eq([456])
      expect(requests.last[:params]).to include(
        expression_attribute_values: { ":pk" => { s: "123" }, ":prefix" => { s: "OPEN#" } }
      )
    end
  end

  describe ".purchase_open_records" do
    let(:purchase_open) do
      {
        "sk" => "OPEN#abc",
        "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment",
        "mailer_args" => "[456, 123]",
        "first_open_at" => "2026-10-01T12:00:00.000Z",
      }
    end

    it "returns the buyer, the recipient digest and the first open of each purchase-keyed open" do
      client.stub_responses(
        :query,
        {
          items: [
            purchase_open,
            { "sk" => "OPEN#def", "mailer_method" => "CreatorContactingCustomersMailer.follower_installment", "mailer_args" => "[9, 123]", "first_open_at" => "2026-10-01T12:00:00.000Z" },
          ],
        }
      )

      expect(described_class.purchase_open_records(123)).to eq(
        [{ purchase_id: 456, recipient_digest: "abc", first_open_at: Time.zone.iso8601("2026-10-01T12:00:00.000Z") }]
      )
    end

    it "drops an open whose timestamp cannot be read" do
      client.stub_responses(:query, { items: [purchase_open.merge("first_open_at" => "not a time")] })

      expect(described_class.purchase_open_records(123)).to eq([])
    end

    it "reads the post's opens off the open-time index" do
      client.stub_responses(:query, { items: [] })

      described_class.purchase_open_records(123)

      params = requests.last[:params]
      expect(params[:index_name]).to eq("pk-first_open_at-index")
      expect(params[:key_condition_expression]).to eq("pk = :pk")
      expect(params[:expression_attribute_values]).to eq({ ":pk" => { s: "123" } })
      expect(params).not_to have_key(:filter_expression)
    end

    it "follows every page of the index" do
      pages = [
        { items: [purchase_open.merge("sk" => "OPEN#one")], last_evaluated_key: { "pk" => "123", "sk" => "OPEN#one", "first_open_at" => "2026-10-01T12:00:00.000Z" } },
        { items: [purchase_open.merge("sk" => "OPEN#two")] },
      ]
      client.stub_responses(:query, pages)

      expect(described_class.purchase_open_records(123).map { _1[:recipient_digest] }).to eq(%w[one two])
      expect(requests.last[:params][:exclusive_start_key]).to be_present
      expect(requests.last[:params][:index_name]).to eq("pk-first_open_at-index")
    end

    context "with a window" do
      let(:opened_after) { Time.zone.iso8601("2026-10-01T00:00:00.000Z") }
      let(:opened_before) { Time.zone.iso8601("2026-10-02T00:00:00.000Z") }

      # The stubbed client ignores key conditions, so apply the one the store sent the way DynamoDB would.
      before do
        opens = {
          "early" => "2026-09-30T23:59:59.999Z",
          "first" => "2026-10-01T00:00:00.000Z",
          "middle" => "2026-10-01T12:00:00.000Z",
          "last" => "2026-10-02T00:00:00.000Z",
          "late" => "2026-10-02T00:00:00.001Z",
        }.map { |digest, first_open_at| purchase_open.merge("sk" => "OPEN##{digest}", "first_open_at" => first_open_at) }
        client.stub_responses(:query, lambda do |context|
          bounds = plain_hash(context.params[:expression_attribute_values])
          { items: opens.select { _1["first_open_at"] >= bounds.fetch(":opened_after", "") && _1["first_open_at"] <= bounds.fetch(":opened_before", "~") } }
        end)
      end

      it "reads only the opens inside the window, both bounds included, as a key condition" do
        records = described_class.purchase_open_records(123, opened_after:, opened_before:)

        expect(records.map { _1[:recipient_digest] }).to eq(%w[first middle last])
        params = requests.last[:params]
        expect(params[:index_name]).to eq("pk-first_open_at-index")
        expect(params[:key_condition_expression]).to eq("pk = :pk AND first_open_at BETWEEN :opened_after AND :opened_before")
        expect(plain_hash(params[:expression_attribute_values])).to eq(
          ":pk" => "123", ":opened_after" => "2026-10-01T00:00:00.000Z", ":opened_before" => "2026-10-02T00:00:00.000Z"
        )
        expect(params).not_to have_key(:filter_expression)
      end

      it "keeps an open at a bound that carries sub-millisecond precision" do
        records = described_class.purchase_open_records(123, opened_after:, opened_before: opened_before + 0.0004)

        expect(records.map { _1[:recipient_digest] }).to eq(%w[first middle last])
      end

      it "bounds only the side it is given" do
        expect(described_class.purchase_open_records(123, opened_after:).map { _1[:recipient_digest] }).to eq(%w[first middle last late])
        expect(requests.last[:params][:key_condition_expression]).to eq("pk = :pk AND first_open_at >= :opened_after")

        expect(described_class.purchase_open_records(123, opened_before:).map { _1[:recipient_digest] }).to eq(%w[early first middle last])
        expect(requests.last[:params][:key_condition_expression]).to eq("pk = :pk AND first_open_at <= :opened_before")
      end

      it "returns nothing without a read when the window is empty" do
        expect(described_class.purchase_open_records(123, opened_after: opened_before + 1, opened_before:)).to eq([])
        expect(requests).to be_empty
      end
    end

    # Runs against DynamoDB Local, so the table create_table! built for the suite has to carry the
    # index and the key condition has to be one DynamoDB accepts.
    context "against the real table" do
      let(:installment_id) { 10**12 + SecureRandom.random_number(10**9) }

      before do
        described_class.client = nil
        described_class.deadline_client = nil
      end

      def open_at(time, purchase_id)
        travel_to(time) do
          described_class.record_open(installment_id:, mailer_method: "CreatorContactingCustomersMailer.purchase_installment", mailer_args: "[#{purchase_id}, #{installment_id}]")
        end
      end

      it "reads only the opens inside the window off the index" do
        open_at(Time.zone.iso8601("2026-10-01T09:00:00.000Z"), 1)
        open_at(Time.zone.iso8601("2026-10-02T09:00:00.000Z"), 2)
        open_at(Time.zone.iso8601("2026-10-03T09:00:00.000Z"), 3)
        described_class.record_click(installment_id:, mailer_method: "CreatorContactingCustomersMailer.purchase_installment", mailer_args: "[2, #{installment_id}]", click_url: "https://example.com")

        records = described_class.purchase_open_records(installment_id, opened_after: Time.zone.iso8601("2026-10-02T00:00:00Z"), opened_before: Time.zone.iso8601("2026-10-02T23:59:59Z"))

        expect(records).to eq([{ purchase_id: 2, recipient_digest: described_class.recipient_digest(mailer_method: "CreatorContactingCustomersMailer.purchase_installment", mailer_args: "[2, #{installment_id}]"), first_open_at: Time.zone.iso8601("2026-10-02T09:00:00.000Z") }])
        expect(described_class.purchase_open_records(installment_id).map { _1[:purchase_id] }).to eq([1, 2, 3])
        expect(described_class.clicked_recipient_digests_among(installment_id, [records.sole[:recipient_digest], "nobody"])).to eq(Set[records.sole[:recipient_digest]])
      end
    end
  end

  describe ".clicked?" do
    it "is true when the recipient has a clicker item" do
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "CLICKER#abc" } })

      expect(described_class.clicked?(installment_id: 123, recipient_digest: "abc")).to be(true)
      expect(requests.last[:params][:key]).to eq({ "pk" => { s: "123" }, "sk" => { s: "CLICKER#abc" } })
    end

    it "is false when the recipient has no clicker item" do
      client.stub_responses(:get_item, { item: nil })

      expect(described_class.clicked?(installment_id: 123, recipient_digest: "abc")).to be(false)
    end

    it "is false without a digest" do
      expect(described_class.clicked?(installment_id: 123, recipient_digest: "")).to be(false)
      expect(requests).to be_empty
    end
  end

  describe ".clicked_recipient_digests" do
    it "returns the digest of each recipient who clicked" do
      client.stub_responses(
        :query,
        {
          items: [
            { "sk" => "CLICKER#abc", "mailer_method" => "CreatorContactingCustomersMailer.purchase_installment", "mailer_args" => "[456, 123]" },
          ],
        }
      )

      expect(described_class.clicked_recipient_digests(123)).to eq(["abc"])
    end
  end

  describe ".clicked_recipient_digests_among" do
    def stub_click_count(count)
      client.stub_responses(:get_item, { item: { "pk" => "123", "sk" => "SUMMARY", "click_count" => count } })
    end

    it "reads nothing without digests" do
      expect(described_class.clicked_recipient_digests_among(123, [nil, ""])).to eq(Set.new)
      expect(requests).to be_empty
    end

    it "stops at the summary when nobody clicked" do
      stub_click_count(0)

      expect(described_class.clicked_recipient_digests_among(123, %w[abc def])).to eq(Set.new)
      expect(requests.map { _1[:operation_name] }).to eq([:get_item])
    end

    it "reads only the asked recipients' clicker items when they are few against the clickers" do
      stub_click_count(1_000)
      client.stub_responses(:batch_get_item, { responses: { described_class.table_name => [{ "sk" => "CLICKER#abc" }] }, unprocessed_keys: {} })

      expect(described_class.clicked_recipient_digests_among(123, %w[abc def])).to eq(Set["abc"])

      batch = requests.find { _1[:operation_name] == :batch_get_item }
      request = batch[:params][:request_items][described_class.table_name]
      expect(request[:keys].map { plain_hash(_1) }).to eq([{ "pk" => "123", "sk" => "CLICKER#abc" }, { "pk" => "123", "sk" => "CLICKER#def" }])
      expect(request[:projection_expression]).to eq("sk")
      expect(requests.map { _1[:operation_name] }).not_to include(:query)
    end

    it "walks the clicker prefix once when the ask is large against the clickers" do
      stub_click_count(3)
      client.stub_responses(:query, { items: [{ "sk" => "CLICKER#abc" }, { "sk" => "CLICKER#zzz" }] })

      expect(described_class.clicked_recipient_digests_among(123, %w[abc def])).to eq(Set["abc"])
      expect(requests.last[:params][:expression_attribute_values]).to include(":prefix" => { s: "CLICKER#" })
      expect(requests.map { _1[:operation_name] }).not_to include(:batch_get_item)
    end

    it "splits more than the batch limit into several batch reads" do
      stub_click_count(10_000)
      digests = (1..150).map { |i| format("%064d", i) }
      client.stub_responses(
        :batch_get_item,
        [
          { responses: { described_class.table_name => [{ "sk" => "CLICKER##{digests[0]}" }] }, unprocessed_keys: {} },
          { responses: { described_class.table_name => [{ "sk" => "CLICKER##{digests[100]}" }] }, unprocessed_keys: {} },
        ]
      )

      expect(described_class.clicked_recipient_digests_among(123, digests)).to eq(Set[digests[0], digests[100]])

      batches = requests.select { |r| r[:operation_name] == :batch_get_item }
      key_lists = batches.map { |b| b[:params][:request_items][described_class.table_name][:keys] }
      expect(key_lists.map(&:size)).to eq([100, 50])
      expect(key_lists.flatten.map { |key| plain_hash(key)["sk"] }).to eq(digests.map { |digest| "CLICKER##{digest}" })
    end

    it "retries the keys DynamoDB leaves unprocessed and keeps the items from both attempts" do
      stub_click_count(1_000)
      allow(described_class).to receive(:sleep)
      client.stub_responses(
        :batch_get_item,
        [
          {
            responses: { described_class.table_name => [{ "sk" => "CLICKER#abc" }] },
            unprocessed_keys: { described_class.table_name => { keys: [{ "pk" => "123", "sk" => "CLICKER#def" }] } },
          },
          { responses: { described_class.table_name => [{ "sk" => "CLICKER#def" }] } },
        ]
      )

      expect(described_class.clicked_recipient_digests_among(123, %w[abc def])).to eq(Set["abc", "def"])
      expect(requests.select { _1[:operation_name] == :batch_get_item }.size).to eq(2)
    end
  end
end
