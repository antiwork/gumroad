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
      create(:sent_post_email, email: "foo") # belongs to another post, so it should not interact with the checks below
      counter = 0
      described_class.ensure_uniqueness(post:, email: "foo") { counter += 1 }
      expect(counter).to eq(1)

      described_class.ensure_uniqueness(post:, email: "FOO") { counter += 1 }
      expect(counter).to eq(1)

      described_class.ensure_uniqueness(post:, email: "bar") { counter += 1 }
      expect(counter).to eq(2)
    end

    it "does not raise error if email is blank" do
      counter = 0
      described_class.ensure_uniqueness(post:, email: "") { counter += 1 }
      expect(counter).to eq(0)

      described_class.ensure_uniqueness(post:, email: nil) { counter += 1 }
      expect(counter).to eq(0)
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
