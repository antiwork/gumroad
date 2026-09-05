# frozen_string_literal: true

require "spec_helper"

# `use_transactional_tests = false` because a shared connection cannot exhibit the race: each worker
# needs its own connection, like two web processes.
describe TotpCredential do
  self.use_transactional_tests = false

  let(:user) { create(:user) }

  before do
    @credential = create(:totp_credential, user:)
    @code = @credential.otp_code
  end

  after do
    # No transaction rollback here, so remove what the examples created.
    TotpCredential.delete_all
    user.destroy! if user.persisted?
  end

  it "rejects the second of two concurrent confirms carrying the same code" do
    # Hold the first confirm open between taking the row lock and minting recovery codes — exactly
    # the window the race lived in — and only release the second confirm once the lock is held, so
    # the ordering does not depend on thread scheduling. Each worker acts on its own instance loaded
    # before the race, like two web processes, so the stale confirmed? read is what the loser would
    # rely on without the row lock.
    lock_held = Queue.new
    allow_any_instance_of(TotpCredential).to receive(:generate_recovery_codes).and_wrap_original do |original, *args|
      if Thread.current[:hold_open_confirm_window]
        lock_held << true
        sleep 1
      end
      original.call(*args)
    end

    first_credential = TotpCredential.find(@credential.id)
    second_credential = TotpCredential.find(@credential.id)
    results = Queue.new

    first = Thread.new do
      Thread.current[:hold_open_confirm_window] = true
      ActiveRecord::Base.connection_pool.with_connection { results << first_credential.confirm(@code) }
    end

    if lock_held.pop(timeout: 20).nil?
      # Surface whatever the first confirm raised instead of blocking on a signal that will never come.
      first.join(5)
      raise "the first confirm never reached the write window"
    end

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { results << second_credential.confirm(@code) }
    end

    [first, second].each { expect(_1.join(20)).to be_present }

    confirmed = Array.new(2) { results.pop }
    expect(confirmed.count { |r| r.is_a?(Array) }).to eq(1)
    expect(confirmed.include?(nil)).to be true

    @credential.reload
    expect(@credential).to be_confirmed
    expect(@credential.recovery_codes.size).to eq(TotpCredential::RECOVERY_CODE_COUNT)
  end

  it "rejects a code on a credential that is already confirmed" do
    @credential.confirm(@code)
    @credential.reload
    codes_before = @credential.recovery_codes

    expect(@credential.confirm(@credential.otp_code)).to be nil
    expect(@credential.reload.recovery_codes).to eq(codes_before)
  end
end