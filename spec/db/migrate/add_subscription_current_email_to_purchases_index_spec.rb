# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261206000029_add_subscription_current_email_to_purchases_index.rb")

# `dynamic: :strict` on the purchases mapping rejects any document carrying a field the live index
# does not know, so without this migration every write of the new field 400s — the backfill's and the
# callbacks' alike.
RSpec.describe AddSubscriptionCurrentEmailToPurchasesIndex do
  let(:index) { "gp1771_mapping_#{SecureRandom.hex(4)}" }

  before do
    allow(Purchase).to receive(:index_name).and_return(index)
    EsClient.indices.create(index:, body: {
                              settings: Purchase.settings.to_hash,
                              mappings: { dynamic: "strict", properties: { "email" => { "type" => "keyword" } } }
                            })
    EsClient.index(index:, id: 1, body: { "email" => "signup@oldmail.example" })
  end

  after { EsClient.indices.delete(index:, ignore: [404]) }

  def write_current_email
    EsClient.update(index:, id: 1, body: { "doc" => { "subscription_current_email" => "newname@newdomain.example" } })
  end

  it "makes the field writable, and it was not writable before" do
    expect { write_current_email }
      .to raise_error(Elasticsearch::Transport::Transport::Errors::BadRequest, /strict_dynamic_mapping_exception/)

    described_class.new.up

    expect { write_current_email }.not_to raise_error
  end

  # The mapping must match the model's, or a reindex writes a field the search clauses cannot use.
  it "matches the mapping the model declares" do
    described_class.new.up

    live = EsClient.indices.get_mapping(index:).dig(index, "mappings", "properties", "subscription_current_email")
    expect(live.deep_transform_values(&:to_s)).to eq(
      Purchase.mappings.to_hash[:properties][:subscription_current_email]
              .deep_stringify_keys.deep_transform_values(&:to_s)
    )
  end
end
