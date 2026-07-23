# frozen_string_literal: true

require "spec_helper"

describe StaleTransientSuppressionSweepJob do
  let(:job) { described_class.new }

  # One fake subuser is enough to exercise the logic; the per-subuser
  # iteration itself is a simple loop over EmailSuppressionManager.subuser_api_keys.
  before do
    allow(EmailSuppressionManager).to receive(:subuser_api_keys).and_return({ gumroad: "SG.test-key" })
  end

  def stub_suppression_entries(bounces: [], blocks: [])
    lists = { bounces:, blocks: }
    suppression = double("suppression")
    lists.each do |list, entries|
      list_client = double("list_client_#{list}")
      # Return all entries on the first page; a short page ends pagination.
      allow(list_client).to receive(:get) do |query_params: {}|
        page = (query_params[:offset].to_i).zero? ? entries : []
        double(parsed_body: page, status_code: "200")
      end
      deletions[list] = []
      allow(list_client).to receive(:_) do |email|
        node = double("delete_node")
        allow(node).to receive(:delete) do
          deletions[list] << email
          double(status_code: "204")
        end
        node
      end
      allow(suppression).to receive(list).and_return(list_client)
    end
    client = double("client", suppression:)
    allow(SendGrid::API).to receive(:new).and_return(double(client:))
  end

  def deletions
    @deletions ||= {}
  end

  def entry(email:, reason: "451 4.4.1 reply: read error", created_at: 10.days.ago)
    { email:, reason:, created: created_at.to_i, status: "4.4.1" }
  end

  describe "#perform" do
    context "when a transient suppression belongs to a user who signed in after it was created" do
      let(:user) { create(:user) }

      before do
        user.update_columns(current_sign_in_at: 1.day.ago)
        stub_suppression_entries(bounces: [entry(email: user.email)])
      end

      it "clears the suppression" do
        job.perform

        expect(deletions[:bounces]).to eq([user.email])
      end
    end

    context "when the user has not signed in since the suppression" do
      let(:user) { create(:user) }

      before do
        user.update_columns(current_sign_in_at: 30.days.ago)
        stub_suppression_entries(bounces: [entry(email: user.email, created_at: 10.days.ago)])
      end

      it "leaves the suppression in place" do
        job.perform

        expect(deletions[:bounces]).to be_empty
      end
    end

    context "when the user has never signed in" do
      let(:user) { create(:user) }

      before do
        user.update_columns(current_sign_in_at: nil)
        stub_suppression_entries(bounces: [entry(email: user.email)])
      end

      it "leaves the suppression in place" do
        job.perform

        expect(deletions[:bounces]).to be_empty
      end
    end

    context "when the suppression reason is a hard failure" do
      let(:user) { create(:user) }

      before do
        user.update_columns(current_sign_in_at: 1.day.ago)
        stub_suppression_entries(bounces: [entry(email: user.email, reason: "550 5.1.1 user unknown")])
      end

      it "leaves the suppression in place" do
        job.perform

        expect(deletions[:bounces]).to be_empty
      end
    end

    context "when the suppression reason is unrecognized" do
      let(:user) { create(:user) }

      before do
        user.update_columns(current_sign_in_at: 1.day.ago)
        stub_suppression_entries(bounces: [entry(email: user.email, reason: "some novel refusal wording")])
      end

      it "leaves the suppression in place (fail-closed)" do
        job.perform

        expect(deletions[:bounces]).to be_empty
      end
    end

    context "when no user exists for the suppressed address" do
      before do
        stub_suppression_entries(bounces: [entry(email: "nobody@example.com")])
      end

      it "leaves the suppression in place" do
        job.perform

        expect(deletions[:bounces]).to be_empty
      end
    end

    it "sweeps the blocks list too" do
      user = create(:user)
      user.update_columns(current_sign_in_at: 1.day.ago)
      stub_suppression_entries(blocks: [entry(email: user.email)])

      job.perform

      expect(deletions[:blocks]).to eq([user.email])
    end

    it "never queries the spam_reports or unsubscribe lists" do
      expect(described_class::SWEPT_LISTS).to eq([:bounces, :blocks])
      stub_suppression_entries
      job.perform
    end

    it "stops clearing at MAX_CLEARS_PER_RUN" do
      stub_const("#{described_class}::MAX_CLEARS_PER_RUN", 2)
      users = Array.new(3) do
        user = create(:user)
        user.update_columns(current_sign_in_at: 1.day.ago)
        user
      end
      stub_suppression_entries(bounces: users.map { |u| entry(email: u.email) })

      job.perform

      expect(deletions[:bounces].size).to eq(2)
    end

    it "splits the clear cap across subusers so a heavy first subuser cannot starve later ones" do
      stub_const("#{described_class}::MAX_CLEARS_PER_RUN", 2)
      allow(EmailSuppressionManager).to receive(:subuser_api_keys)
        .and_return({ gumroad: "SG.key-a", followers: "SG.key-b" })
      users = Array.new(3) do
        user = create(:user)
        user.update_columns(current_sign_in_at: 1.day.ago)
        user
      end
      entries = users.map { |u| entry(email: u.email) }

      deletions_by_key = { "SG.key-a" => [], "SG.key-b" => [] }
      allow(SendGrid::API).to receive(:new) do |api_key:|
        list_client = double("list_client")
        allow(list_client).to receive(:get)
          .and_return(double(parsed_body: entries, status_code: "200"))
        allow(list_client).to receive(:_) do |email|
          node = double("delete_node")
          allow(node).to receive(:delete) do
            deletions_by_key[api_key] << email
            double(status_code: "204")
          end
          node
        end
        suppression = double("suppression", bounces: list_client, blocks: double("blocks", get: double(parsed_body: [], status_code: "200")))
        double(client: double(suppression:))
      end

      job.perform

      # Budget is 2 / 2 subusers = 1 each: both subusers clear exactly one
      # entry instead of the first consuming the whole cap.
      expect(deletions_by_key["SG.key-a"].size).to eq(1)
      expect(deletions_by_key["SG.key-b"].size).to eq(1)
    end

    it "continues with the next list when one list errors" do
      user = create(:user)
      user.update_columns(current_sign_in_at: 1.day.ago)
      stub_suppression_entries(blocks: [entry(email: user.email)])
      # Make the bounces list blow up; the blocks sweep must still run.
      suppression = SendGrid::API.new(api_key: "x").client.suppression
      allow(suppression.bounces).to receive(:get).and_raise(StandardError.new("rate limited"))
      allow(ErrorNotifier).to receive(:notify)

      job.perform

      expect(ErrorNotifier).to have_received(:notify)
      expect(deletions[:blocks]).to eq([user.email])
    end

    it "pages through the list until a short page signals the end" do
      stub_const("#{described_class}::PAGE_SIZE", 2)
      users = Array.new(3) do
        user = create(:user)
        user.update_columns(current_sign_in_at: 1.day.ago)
        user
      end
      entries = users.map { |u| entry(email: u.email) }
      pages = [entries.first(2), entries.drop(2)]

      suppression = double("suppression")
      deletions[:bounces] = []
      deletions[:blocks] = []
      requested_offsets = []
      bounces_client = double("bounces_client")
      allow(bounces_client).to receive(:get) do |query_params: {}|
        offset = query_params[:offset].to_i
        requested_offsets << offset
        double(parsed_body: pages[offset / 2] || [], status_code: "200")
      end
      allow(bounces_client).to receive(:_) do |email|
        node = double("delete_node")
        allow(node).to receive(:delete) do
          deletions[:bounces] << email
          double(status_code: "204")
        end
        node
      end
      blocks_client = double("blocks_client")
      allow(blocks_client).to receive(:get).and_return(double(parsed_body: [], status_code: "200"))
      allow(suppression).to receive(:bounces).and_return(bounces_client)
      allow(suppression).to receive(:blocks).and_return(blocks_client)
      allow(SendGrid::API).to receive(:new).and_return(double(client: double(suppression:)))

      job.perform

      expect(requested_offsets).to eq([0, 2])
      expect(deletions[:bounces]).to match_array(users.map(&:email))
    end

    it "logs when the page bound is exhausted so a huge list is not silently truncated" do
      stub_const("#{described_class}::PAGE_SIZE", 1)
      stub_const("#{described_class}::MAX_PAGES_PER_LIST", 2)
      # Every fetched page comes back full (size == PAGE_SIZE), so the job
      # hits the page bound without ever seeing a short page.
      full_page = [entry(email: "full-page@example.com")]
      list_client = double("list_client")
      allow(list_client).to receive(:get).and_return(double(parsed_body: full_page, status_code: "200"))
      blocks_client = double("blocks_client")
      allow(blocks_client).to receive(:get).and_return(double(parsed_body: [], status_code: "200"))
      suppression = double("suppression", bounces: list_client, blocks: blocks_client)
      allow(SendGrid::API).to receive(:new).and_return(double(client: double(suppression:)))
      allow(Rails.logger).to receive(:info).and_call_original

      job.perform

      expect(Rails.logger).to have_received(:info)
        .with(a_string_including("page bound (2 pages) reached for bounces"))
    end

    it "notifies and skips the list when SendGrid returns a non-2xx status without raising" do
      user = create(:user)
      user.update_columns(current_sign_in_at: 1.day.ago)
      stub_suppression_entries(blocks: [entry(email: user.email)])
      suppression = SendGrid::API.new(api_key: "x").client.suppression
      # A structured auth failure arrives as a parsed error hash, not an
      # exception — it must be surfaced, not treated as an empty list.
      allow(suppression.bounces).to receive(:get)
        .and_return(double(parsed_body: { errors: [{ message: "authorization required" }] }, status_code: "401"))
      allow(ErrorNotifier).to receive(:notify)

      job.perform

      expect(ErrorNotifier).to have_received(:notify)
      expect(deletions[:blocks]).to eq([user.email])
    end

    it "notifies when a 2xx response has an unexpected (non-array) body" do
      stub_suppression_entries
      suppression = SendGrid::API.new(api_key: "x").client.suppression
      allow(suppression.bounces).to receive(:get).and_return(double(parsed_body: { error: "nope" }, status_code: "200"))
      allow(ErrorNotifier).to receive(:notify)

      expect { job.perform }.not_to raise_error
      expect(ErrorNotifier).to have_received(:notify)
    end
  end
end
