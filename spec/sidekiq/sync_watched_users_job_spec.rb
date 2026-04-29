# frozen_string_literal: true

require "spec_helper"

describe SyncWatchedUsersJob do
  describe "#perform" do
    it "syncs every alive watched user" do
      alive_watch = create(:watched_user)
      other_alive_watch = create(:watched_user)
      deleted_watch = create(:watched_user)
      deleted_watch.mark_deleted!

      described_class.new.perform

      expect(alive_watch.reload.last_synced_at).to be_present
      expect(other_alive_watch.reload.last_synced_at).to be_present
      expect(deleted_watch.reload.last_synced_at).to be_nil
    end

    it "notifies on per-record errors but continues processing" do
      first = create(:watched_user)
      second = create(:watched_user)

      allow_any_instance_of(WatchedUser).to receive(:sync!).and_wrap_original do |original, *args|
        if original.receiver.id == first.id
          raise StandardError, "boom"
        else
          original.call(*args)
        end
      end

      expect(ErrorNotifier).to receive(:notify).with(instance_of(StandardError), context: { watched_user_id: first.id })

      described_class.new.perform

      expect(second.reload.last_synced_at).to be_present
    end
  end
end
