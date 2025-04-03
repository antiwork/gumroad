# frozen_string_literal: true

require "spec_helper"

describe DevTools do
  # Very basic tests just to guard for basic runtime errors (method not found, etc).
  describe ".reindex_all_for_user" do
    it "succeeds after indexing at least one record" do
      product = create(:product)
      Link.__elasticsearch__.create_index!(force: true)
      described_class.reindex_all_for_user(product.user)
      expect(get_product_document(product.id)["found"]).to eq(true)
    end

    it "does not delete the indices" do
      product = create(:product)
      Link.__elasticsearch__.create_index!(force: true)
      EsClient.index(index: Link.index_name, id: "test", body: {})
      described_class.reindex_all_for_user(product.user)
      expect(get_product_document("test")["found"]).to eq(true)
      expect(get_product_document(product.id)["found"]).to eq(true)
    end
  end

  describe ".delete_all_indices_and_reindex_all" do
    it "succeeds after indexing at least one record" do
      product = create(:product)
      Link.__elasticsearch__.delete_index!(force: true)
      described_class.delete_all_indices_and_reindex_all
      expect(get_product_document(product.id)["found"]).to eq(true)
    end

    it "does not execute in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      Link.__elasticsearch__.create_index!(force: true)
      EsClient.index(index: Link.index_name, id: "test", body: {})
      expect { described_class.delete_all_indices_and_reindex_all }.to raise_error(StandardError, /production/)
      expect(get_product_document("test")["found"]).to eq(true)
    end
  end

  describe ".reimport_follower_events_for_user!" do
    let(:index_class) { ConfirmedFollowerEvent }
    let(:index_name) { index_class.index_name }

    it "delete all events and creates events for every confirmed follower" do
      user = create(:user)

      EsClient.index(index: index_name, body: { name: "added", followed_user_id: user.id, timestamp: 10.days.ago })
      EsClient.index(index: index_name, body: { name: "removed", followed_user_id: user.id, timestamp: 9.days.ago })
      EsClient.index(index: index_name, body: { name: "added", followed_user_id: user.id, timestamp: 8.days.ago })
      event_belonging_to_another_user_id = SecureRandom.uuid
      EsClient.index(index: index_name, id: event_belonging_to_another_user_id, body: { name: "added", timestamp: 10.days.ago })
      index_class.__elasticsearch__.refresh_index!

      create(:follower, user:)
      create(:deleted_follower, user:)
      followers = [
        create(:active_follower, user:, confirmed_at: Time.utc(2021, 1)),
        create(:active_follower, user:, confirmed_at: Time.utc(2021, 2))
      ]

      described_class.reimport_follower_events_for_user!(user)
      index_class.__elasticsearch__.refresh_index!

      documents = EsClient.search(
        index: index_name,
        body: { query: { term: { followed_user_id: user.id } }, sort: :timestamp }
      )["hits"]["hits"]

      expect(documents.size).to eq(2)
      expect(documents[0]["_source"]).to eq(
        "name" => "added",
        "timestamp" => "2021-01-01T00:00:00Z",
        "follower_id" => followers[0].id,
        "followed_user_id" => followers[0].user.id,
        "follower_user_id" => nil,
        "email" => followers[0].email
      )
      expect(documents[1]["_source"]).to eq(
        "name" => "added",
        "timestamp" => "2021-02-01T00:00:00Z",
        "follower_id" => followers[1].id,
        "followed_user_id" => followers[1].user.id,
        "follower_user_id" => nil,
        "email" => followers[1].email
      )

      # check the event belonging to another user was not deleted
      expect do
        EsClient.get(index: index_name, id: event_belonging_to_another_user_id)
      end.not_to raise_error
    end
  end

  def get_product_document(document_id)
    EsClient.get(index: Link.index_name, id: document_id, ignore: [404])
  end
end
