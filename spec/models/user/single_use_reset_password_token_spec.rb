# frozen_string_literal: true

require "spec_helper"

# `use_transactional_tests = false` because a shared connection cannot exhibit the race: each worker
# needs its own connection, like two web processes.
describe User::SingleUseResetPasswordToken do
  self.use_transactional_tests = false

  before do
    @user = create(:user, password: "original-password-1")
    @token = @user.send(:set_reset_password_token)
    @user.save!
  end

  after do
    # No transaction rollback here, so remove what the examples created. `destroy!` does not reach
    # the user's global affiliate (`has_one` with no `dependent:`), and an orphaned one breaks any
    # later example that asserts against all GlobalAffiliate rows.
    Affiliate.where(affiliate_user_id: @user.id).delete_all
    PaperTrail::Version.where(item_type: "User", item_id: @user.id).delete_all
    @user.reload.destroy!
  end

  def consume(token, password)
    User.reset_password_by_token(
      reset_password_token: token,
      password:,
      password_confirmation: password
    )
  end

  it "rejects the second of two concurrent submissions carrying the same token" do
    # Hold the first request open between taking the lock and saving the new password — exactly the
    # window the race lived in — and only release the second request once the lock is held, so the
    # ordering does not depend on thread scheduling.
    lock_held = Queue.new
    allow_any_instance_of(User).to receive(:reset_password).and_wrap_original do |original, *args|
      if Thread.current[:hold_open_reset_window]
        lock_held << true
        sleep 1
      end
      original.call(*args)
    end

    first = nil
    second = nil

    winner = Thread.new do
      Thread.current[:hold_open_reset_window] = true
      ActiveRecord::Base.connection_pool.with_connection { first = consume(@token, "winning-password-1") }
    end

    lock_held.pop

    loser = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { second = consume(@token, "losing-password-1") }
    end

    [winner, loser].each { expect(_1.join(20)).to be_present }

    expect([first, second].count { _1.errors.empty? }).to eq(1)
    rejected = [first, second].find { _1.errors.any? }
    expect(rejected.errors[:reset_password_token]).to be_present

    @user.reload
    expect(@user.valid_password?("winning-password-1")).to be(true)
    expect(@user.valid_password?("losing-password-1")).to be(false)
    expect(@user.reset_password_token).to be_nil
  end

  it "rejects a token that has already been consumed" do
    expect(consume(@token, "new-password-1").errors).to be_empty

    reused = consume(@token, "another-password-1")

    expect(reused.errors[:reset_password_token]).to be_present
    expect(@user.reload.valid_password?("new-password-1")).to be(true)
  end

  it "rejects a blank token without querying for a lock" do
    expect(consume("", "new-password-1").errors[:reset_password_token]).to be_present
    expect(consume(nil, "new-password-1").errors[:reset_password_token]).to be_present
    expect(@user.reload.valid_password?("original-password-1")).to be(true)
  end
end
