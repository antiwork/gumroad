# frozen_string_literal: true

require "spec_helper"

describe SentPostEmail do
  let(:post) { create(:post) }

  describe "creation" do
    it "downcases email" do
      record = create(:sent_post_email, email: "FOO")
      expect(record.reload.email).to eq("foo")
    end

    it "ensures emails are unique for each post" do
      create(:sent_post_email, post:, email: "foo")
      create(:sent_post_email, email: "foo") # belongs to another post, so the record above is still unique
      expect do
        create(:sent_post_email, post:, email: "FOO")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".ids_for_email" do
    it "returns the address's rows across every post" do
      first_row = create(:sent_post_email, email: "buyer@example.com")
      second_row = create(:sent_post_email, email: "buyer@example.com")
      create(:sent_post_email, email: "other@example.com")

      expect(described_class.ids_for_email("buyer@example.com")).to match_array([first_row.id, second_row.id])
    end

    # A skip scan of (post_id, email) seeks once per distinct post_id, and a scan reads every row, so on
    # production's table either runs past max_execution_time. Only the address's own entries may be read.
    it "reads only the address's entries in the email index" do
      subject_rows = create_list(:sent_post_email, 2, email: "buyer@example.com")
      described_class.insert_all!((1..50).map { attributes_for(:sent_post_email, post_id: _1, email: "recipient#{_1}@example.com") })
      handler_reads = -> { described_class.connection.select_rows("SHOW SESSION STATUS LIKE 'Handler_read%'").sum { _2.to_i } }
      sql = nil
      capture = ->(*, payload) { sql = payload[:sql] if payload[:sql].include?("sent_post_emails") }

      reads_before = handler_reads.call
      ids = ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
        described_class.ids_for_email("buyer@example.com")
      end
      reads = handler_reads.call - reads_before

      expect(ids).to match_array(subject_rows.map(&:id))
      plan = described_class.connection.select_all("EXPLAIN #{sql}").first
      expect(plan.values_at("type", "key")).to eq(["ref", "index_sent_post_emails_on_email"])
      expect(reads).to be <= subject_rows.size + 1
    end
  end

  describe ".missing_emails" do
    it "returns array of emails currently not stored" do
      create(:sent_post_email, post:, email: "foo")
      create(:sent_post_email, post:, email: "bar")
      create(:sent_post_email, email: "missing1") # belongs to another post, so it's missing for `post`
      result = described_class.missing_emails(post:, emails: ["foo", "missing1", "bar", "missing2"])
      expect(result).to match_array(["missing1", "missing2"])
    end
  end

  describe ".ensure_uniqueness" do
    it "runs block if we successfully created a unique record for that post and email" do
      create(:sent_post_email, email: "foo@example.com") # belongs to another post, so it should not interact with the checks below
      counter = 0
      described_class.ensure_uniqueness(post:, email: "foo@example.com", source: create(:follower, email: "foo@example.com")) { counter += 1 }
      expect(counter).to eq(1)

      # Follower keeps the case it was given, so this reaches the unique key rather than the source check.
      mixed_case_source = create(:follower, email: "FOO@example.com")
      logged = []
      allow(Rails.logger).to receive(:info).and_wrap_original { |original, message| logged << message.to_s; original.call(message) }
      described_class.ensure_uniqueness(post:, email: mixed_case_source.email, source: mixed_case_source) { counter += 1 }
      expect(counter).to eq(1)
      expect(logged.grep(/SentPostEmail: skipped/)).to be_empty

      described_class.ensure_uniqueness(post:, email: "baz@example.com", source: create(:purchase, email: "baz@example.com")) { counter += 1 }
      expect(counter).to eq(2)

      described_class.ensure_uniqueness(post:, email: "bar@example.com", source: create(:user, email: "bar@example.com")) { counter += 1 }
      expect(counter).to eq(3)
      expect(described_class.where(post:).pluck(:email)).to match_array(["foo@example.com", "baz@example.com", "bar@example.com"])
    end

    it "does not raise error if email is blank" do
      counter = 0
      described_class.ensure_uniqueness(post:, email: "", source: nil) { counter += 1 }
      expect(counter).to eq(0)

      described_class.ensure_uniqueness(post:, email: nil, source: nil) { counter += 1 }
      expect(counter).to eq(0)
    end

    # An erasure that commits between reading the address and claiming it rewrites or removes the source.
    {
      "purchase" => -> { create(:purchase, email: "buyer@example.com") },
      "follower" => -> { create(:follower, email: "buyer@example.com") },
      "user" => -> { create(:user, email: "buyer@example.com") },
    }.each do |name, build_source|
      it "claims nothing and does not run the block once the #{name} no longer holds the address" do
        rewritten = instance_exec(&build_source)
        captured_email = rewritten.email
        rewritten.class.where(id: rewritten.id).update_all(email: "deleted-1@deleted.gumroad.com")
        counter = 0
        logged = []
        allow(Rails.logger).to receive(:info).and_wrap_original { |original, message| logged << message.to_s; original.call(message) }

        described_class.ensure_uniqueness(post:, email: captured_email, source: rewritten) { counter += 1 }
        rewritten.class.where(id: rewritten.id).delete_all
        described_class.ensure_uniqueness(post:, email: captured_email, source: rewritten) { counter += 1 }

        expect(counter).to eq(0)
        expect(described_class.where(post:)).to be_empty
        skip_line = "SentPostEmail: skipped post #{post.id} for #{rewritten.class.name} #{rewritten.id}, whose address changed"
        expect(logged.count(skip_line)).to eq(2)
        expect(logged.join).not_to include("buyer@example.com", "deleted-1@deleted.gumroad.com")
      end
    end
  end

  describe ".insert_all_emails" do
    it "inserts all emails, even if some already exist, and returns newly inserted" do
      create(:sent_post_email, post:, email: "foo")
      create(:sent_post_email, email: "bar") # belongs to another post, so it should not interact with the checks below
      expect(described_class.insert_all_emails(post:, emails: ["foo", "bar", "baz"])).to eq(["bar", "baz"])
      expect(described_class.where(post:, email: ["foo", "bar", "baz"]).count).to eq(3)
      # also works if all emails already exist
      expect(described_class.insert_all_emails(post:, emails: ["foo", "bar", "baz"])).to eq([])
      expect(described_class.where(post:, email: ["foo", "bar", "baz"]).count).to eq(3)
    end
  end
end
