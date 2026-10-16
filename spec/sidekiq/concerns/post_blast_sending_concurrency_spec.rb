# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe PostBlastSending, "recording accepted recipients while a member row is locked" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @post = create(:seller_post, seller: @seller)
    @contended = create(:audience_member, seller: @seller, email: "contended@example.com")
    @unrelated = create(:audience_member, seller: @seller, email: "unrelated@example.com")
  end

  after do
    SentPostEmail.where(post_id: @post.id).delete_all
    AudienceMember.where(seller_id: @seller.id).delete_all
    Installment.where(id: @post.id).delete_all
    @seller.destroy!
  end

  # An erasure holds its row locks until it commits, so the wait for its member can outlast every
  # post-acceptance attempt. The slice then raises for a job retry, and only the locked member's row
  # may be missing from it.
  it "keeps the other recipients' rows when waiting for a locked member times out" do
    members = AudienceMember.where(id: [@contended.id, @unrelated.id]).select(:id, :email).to_a
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          connection.execute("UPDATE audience_members SET email = 'deleted-1@deleted.gumroad.com' WHERE id = #{@contended.id}")
          locked << true
          release.pop
          raise ActiveRecord::Rollback
        end
      end
    end
    Timeout.timeout(10) { locked.pop }
    sender = SendPostBlastEmailsJob.new.tap { _1.instance_variable_set(:@post, @post) }
    allow(sender).to receive(:sleep)
    ActiveRecord::Base.connection.execute("SET SESSION innodb_lock_wait_timeout = 1")

    expect { sender.send(:store_recipients_as_sent, members) }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(SentPostEmail.where(post_id: @post.id).pluck(:email)).to eq(["unrelated@example.com"])
  ensure
    ActiveRecord::Base.connection.execute("SET SESSION innodb_lock_wait_timeout = DEFAULT")
    release << true
    holder&.join(10)
  end

  it "skips an address another connection recorded after the write transaction's snapshot" do
    # A fallback that re-reads the snapshot never sees the duplicate, so it retries the insert forever.
    outcome = begin
      Timeout.timeout(10) do
        ActiveRecord::Base.transaction do
          SentPostEmail.where(post_id: @post.id).to_a # the first plain read fixes the snapshot
          Thread.new { ActiveRecord::Base.connection_pool.with_connection { SentPostEmail.create!(post_id: @post.id, email: "unrelated@example.com") } }.join(10)
          SentPostEmail.insert_all_emails(post: @post, emails: ["unrelated@example.com", "contended@example.com"])
        end
      end
    rescue SystemStackError, Timeout::Error => e
      e.class
    end

    expect(outcome).to eq(["contended@example.com"])
    expect(SentPostEmail.where(post_id: @post.id).order(:email).pluck(:email)).to eq(["contended@example.com", "unrelated@example.com"])
  end
end
