# frozen_string_literal: true

require "spec_helper"

describe Installment::Searchable do
  describe "#as_indexed_json" do
    let(:installment) { create(:published_installment, name: "First post", message: "<p>body</p>") }

    it "includes all fields" do
      expect(installment.as_indexed_json).to eq(
        "message" => "<p>body</p>",
        "created_at" => installment.created_at.utc.iso8601,
        "deleted_at" => nil,
        "published_at" => installment.published_at.utc.iso8601,
        "id" => installment.id,
        "seller_id" => installment.seller_id,
        "workflow_id" => installment.workflow_id,
        "name" => "First post",
        "selected_flags" => ["send_emails", "allow_comments"],
      )
    end

    it "allows only a selection of fields to be used" do
      expect(installment.as_indexed_json(only: ["name"])).to eq(
        "name" => "First post"
      )
    end
  end
end
