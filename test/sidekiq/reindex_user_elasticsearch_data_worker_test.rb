# frozen_string_literal: true

require "test_helper"

class ReindexUserElasticsearchDataWorkerTest < ActiveSupport::TestCase
  self.described_class = ReindexUserElasticsearchDataWorker


  context_ ReindexUserElasticsearchDataWorker do
  test "reindexes ES data for user" do
      user = create(:user)
      admin = create(:admin_user)
      allow(DevTools).to receive(:reindex_all_for_user).and_return(nil)

      expect(DevTools).to receive(:reindex_all_for_user).with(user.id)
      described_class.new.perform(user.id, admin.id)

      admin_comment = user.comments.last
      expect(admin_comment.content).to eq("Refreshed ES Data")
      expect(admin_comment.author_id).to eq(admin.id)
    end
  end
end
