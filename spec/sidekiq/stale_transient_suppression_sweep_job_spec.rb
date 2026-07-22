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
      allow(list_client).to receive(:get).and_return(double(parsed_body: entries))
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

    it "handles an unexpected (non-array) SendGrid response by skipping the list" do
      stub_suppression_entries
      suppression = SendGrid::API.new(api_key: "x").client.suppression
      allow(suppression.bounces).to receive(:get).and_return(double(parsed_body: { error: "nope" }))

      expect { job.perform }.not_to raise_error
    end
  end
end
