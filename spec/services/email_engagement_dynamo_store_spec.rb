# frozen_string_literal: true

describe EmailEngagementDynamoStore do
  let(:client) { Aws::DynamoDB::Client.new(stub_responses: true) }
  let(:mailer_method) { "CreatorContactingCustomersMailer.purchase_installment" }
  let(:mailer_args) { "[123, 456]" }
  let(:recipient_digest) { Digest::SHA256.hexdigest("#{mailer_method}\n#{mailer_args}") }
  let(:click_url) { "https://www&#46;gumroad&#46;com/checkout" }
  let(:url_digest) { Digest::SHA256.hexdigest(click_url) }

  before do
    Feature.activate(:email_engagement_dynamodb_dual_write)
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

  describe ".record_open" do
    it "does nothing when the feature flag is inactive" do
      Feature.deactivate(:email_engagement_dynamodb_dual_write)

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests).to be_empty
    end

    it "upserts the open item and increments the summary open count on a recipient's first open" do
      client.stub_responses(:update_item, [{ attributes: {} }, {}])

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests.map { _1[:operation_name] }).to eq([:update_item, :update_item])

      open_upsert = requests.first[:params]
      expect(open_upsert[:table_name]).to eq("email_engagement")
      expect(plain_hash(open_upsert[:key])).to eq("pk" => "123", "sk" => "OPEN##{recipient_digest}")
      expect(open_upsert[:update_expression]).to include("ADD open_count :one")
      expect(open_upsert[:update_expression]).to include("first_open_at = if_not_exists(first_open_at, :now)")
      expect(plain(open_upsert[:expression_attribute_values][":mailer_method"])).to eq(mailer_method)
      expect(plain(open_upsert[:expression_attribute_values][":mailer_args"])).to eq(mailer_args)
      expect(open_upsert[:return_values]).to eq("ALL_OLD")

      summary_update = requests.last[:params]
      expect(plain_hash(summary_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_update[:update_expression]).to eq("ADD #counter :one")
      expect(summary_update[:expression_attribute_names]).to eq("#counter" => "open_count")
    end

    it "does not touch the summary when the recipient has opened before" do
      client.stub_responses(:update_item, { attributes: { "open_count" => 2 } })

      described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)

      expect(requests.map { _1[:operation_name] }).to eq([:update_item])
    end

    it "notifies instead of raising when DynamoDB fails" do
      client.stub_responses(:update_item, "InternalServerError")
      expect(ErrorNotifier).to receive(:notify).with(kind_of(Aws::Errors::ServiceError))

      expect do
        described_class.record_open(installment_id: 123, mailer_method:, mailer_args:)
      end.not_to raise_error
    end
  end

  describe ".record_click" do
    it "does nothing when the feature flag is inactive" do
      Feature.deactivate(:email_engagement_dynamodb_dual_write)

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests).to be_empty
    end

    it "records a first-ever click with the url total, the clicker marker, the summary click count, and a compensating open" do
      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq(
        [:put_item, :update_item, :put_item, :update_item, :put_item, :update_item]
      )

      click_put = requests[0][:params]
      expect(plain(click_put[:item]["pk"])).to eq("123")
      expect(plain(click_put[:item]["sk"])).to eq("CLICK##{recipient_digest}##{url_digest}")
      expect(plain(click_put[:item]["click_url"])).to eq(click_url)
      expect(plain(click_put[:item]["click_count"])).to eq(1)
      expect(click_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      url_update = requests[1][:params]
      expect(plain_hash(url_update[:key])).to eq("pk" => "123", "sk" => "URL##{url_digest}")
      expect(url_update[:update_expression]).to eq("ADD click_count :one SET click_url = :click_url")
      expect(plain(url_update[:expression_attribute_values][":click_url"])).to eq(click_url)

      marker_put = requests[2][:params]
      expect(plain(marker_put[:item]["pk"])).to eq("123")
      expect(plain(marker_put[:item]["sk"])).to eq("CLICKER##{recipient_digest}")
      expect(plain(marker_put[:item]["mailer_args"])).to eq(mailer_args)
      expect(marker_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      summary_click_update = requests[3][:params]
      expect(plain_hash(summary_click_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_click_update[:expression_attribute_names]).to eq("#counter" => "click_count")

      open_put = requests[4][:params]
      expect(plain(open_put[:item]["pk"])).to eq("123")
      expect(plain(open_put[:item]["sk"])).to eq("OPEN##{recipient_digest}")
      expect(plain(open_put[:item]["open_count"])).to eq(1)
      expect(open_put[:condition_expression]).to eq("attribute_not_exists(pk)")

      summary_open_update = requests[5][:params]
      expect(plain_hash(summary_open_update[:key])).to eq("pk" => "123", "sk" => "SUMMARY")
      expect(summary_open_update[:expression_attribute_names]).to eq("#counter" => "open_count")
    end

    it "does not increment the summary click count when the recipient has clicked another url before" do
      # The click item put succeeds; the clicker marker already exists, as does the open item.
      client.stub_responses(:put_item, [{}, "ConditionalCheckFailedException", "ConditionalCheckFailedException"])

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:put_item, :update_item, :put_item, :put_item])
      expect(plain(requests[1][:params][:key]["sk"])).to eq("URL##{url_digest}")
      expect(plain(requests[2][:params][:item]["sk"])).to eq("CLICKER##{recipient_digest}")
    end

    it "counts nothing on a repeat click of the same url by the same recipient" do
      client.stub_responses(:put_item, "ConditionalCheckFailedException")

      described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)

      expect(requests.map { _1[:operation_name] }).to eq([:put_item])
    end

    it "notifies instead of raising when DynamoDB fails" do
      client.stub_responses(:put_item, "ProvisionedThroughputExceededException")
      expect(ErrorNotifier).to receive(:notify).with(kind_of(Aws::Errors::ServiceError))

      expect do
        described_class.record_click(installment_id: 123, mailer_method:, mailer_args:, click_url:)
      end.not_to raise_error
    end
  end

  describe ".table_name" do
    it "prepends DYNAMODB_TABLE_PREFIX when set" do
      expect(described_class.table_name).to eq("email_engagement")

      ENV["DYNAMODB_TABLE_PREFIX"] = "lane1_"
      expect(described_class.table_name).to eq("lane1_email_engagement")
    ensure
      ENV.delete("DYNAMODB_TABLE_PREFIX")
    end

    it "defaults to the Terraform-owned per-environment table in production and staging" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      expect(described_class.table_name).to eq("production-email_engagement")

      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      expect(described_class.table_name).to eq("staging-email_engagement")
    end

    it "lets DYNAMODB_TABLE_PREFIX override the environment default for branch apps" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("staging"))
      ENV["DYNAMODB_TABLE_PREFIX"] = "branchapp-foo-"
      expect(described_class.table_name).to eq("branchapp-foo-email_engagement")
    ensure
      ENV.delete("DYNAMODB_TABLE_PREFIX")
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
      expect(request[:params][:table_name]).to eq("email_engagement")
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
end
