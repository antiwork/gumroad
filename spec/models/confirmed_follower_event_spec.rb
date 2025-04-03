# frozen_string_literal: true

require "spec_helper"

describe ConfirmedFollowerEvent do
  it "can have documents added to its index" do
    document_id = SecureRandom.uuid
    EsClient.index(
      index: described_class.index_name,
      id: document_id,
      body: {
        "followed_user_id" => 123,
        "name" => "added",
        "timestamp" => Time.utc(2021, 7, 20, 1, 2, 3)
      }.to_json
    )

    document = EsClient.get(index: described_class.index_name, id: document_id).fetch("_source")
    expect(document).to eq(
      "followed_user_id" => 123,
      "name" => "added",
      "timestamp" => "2021-07-20T01:02:03Z"
    )
  end

  describe "Follower Callbacks" do
    before do
      allow(SecureRandom).to receive(:uuid).and_return("fake-random-uuid")
      @follower = create(:follower, follower_user_id: build(:user))
      ElasticsearchIndexerWorker.jobs.clear
    end

    it "queues job when confirmation state changes" do
      # confirming queues a "added" event
      travel_to Time.utc(2021, 7, 1, 2, 3, 4) do
        @follower.confirm!
      end

      expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", {
                                                                        class_name: described_class.name,
                                                                        id: "fake-random-uuid",
                                                                        body: {
                                                                          name: "added",
                                                                          timestamp: "2021-07-01T02:03:04Z",
                                                                          follower_id: @follower.id,
                                                                          followed_user_id: @follower.followed_id,
                                                                          follower_user_id: @follower.follower_user_id,
                                                                          email: @follower.email
                                                                        }
                                                                      })
      ElasticsearchIndexerWorker.jobs.clear

      # Sanity check: changing the value of confirmed_at from a datetime to another datetime should not queue a job
      @follower.update!(confirmed_at: Time.utc(2020, 1, 1), deleted_at: nil)
      expect(ElasticsearchIndexerWorker.jobs.size).to eq(0)

      # unfollowing (= deleting) queues a "removed" event
      travel_to Time.utc(2021, 7, 2, 3, 4, 5) do
        @follower.mark_deleted!
      end
      expect(ElasticsearchIndexerWorker).to have_enqueued_sidekiq_job("index", {
                                                                        class_name: described_class.name,
                                                                        id: "fake-random-uuid",
                                                                        body: {
                                                                          name: "removed",
                                                                          timestamp: "2021-07-02T03:04:05Z",
                                                                          follower_id: @follower.id,
                                                                          followed_user_id: @follower.followed_id,
                                                                          follower_user_id: @follower.follower_user_id,
                                                                          email: @follower.email
                                                                        }
                                                                      })
      ElasticsearchIndexerWorker.jobs.clear
    end
  end
end
