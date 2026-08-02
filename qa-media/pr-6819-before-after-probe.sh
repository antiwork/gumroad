#!/bin/bash
# Reproduces qa-media/pr-6819-before-after-refunded-deposit.png.
#
# Runs one probe spec twice in the same worktree, swapping ONLY
# app/models/commission.rb between origin/main and this branch. Everything else
# — fixture, VCR cassette, database — is identical across the two legs, so the
# only thing that can explain a difference in the output is the guard.
#
# Purchase#process! is stubbed in both legs: no money moves recording this. The
# measurement is whether the charge path is REACHED, which is the defect.
#
# Usage:  bash qa-media/pr-6819-before-after-probe.sh
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
export PATH="$HOME/.rbenv/shims:$PATH" DISABLE_SPRING=1 OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

PROBE=spec/zz_gp1666_probe_spec.rb
cat > "$PROBE" <<'PROBE_SPEC'
# frozen_string_literal: true

require "spec_helper"

describe "gp1666 probe", :vcr do
  it "reports the outcome of Mark complete on a refunded deposit" do
    leg = ENV.fetch("PROBE_LEG", "unknown")

    commission = create(:commission, status: Commission::STATUS_IN_PROGRESS)
    deposit = commission.deposit_purchase
    deposit.update!(stripe_refunded: true)

    charge_submissions = 0
    allow_any_instance_of(Purchase).to receive(:process!) { charge_submissions += 1 }
    allow_any_instance_of(Purchase).to receive(:update_balance_and_mark_successful!) { true }

    before_count = Purchase.count
    error_message = nil

    begin
      commission.create_completion_purchase!
    rescue ActiveRecord::RecordInvalid => e
      error_message = e.record&.errors&.full_messages&.join("; ")
    rescue StandardError => e
      error_message = "#{e.class}: #{e.message}"
    end

    commission.reload
    puts ""
    puts "PROBE#{leg} deposit_state             = #{deposit.reload.purchase_state}, refunded=#{deposit.refunded?}"
    puts "PROBE#{leg} card submitted for charge = #{charge_submissions > 0 ? "YES  <-- buyer charged" : "NO   <-- refused"}"
    puts "PROBE#{leg} Purchase rows created     = #{Purchase.count - before_count}"
    puts "PROBE#{leg} completion_purchase       = #{commission.completion_purchase.nil? ? "nil" : commission.completion_purchase.id}"
    puts "PROBE#{leg} commission status after   = #{commission.status}"
    puts "PROBE#{leg} seller sees               = #{error_message || "(no error — completion proceeded)"}"
    puts ""
  end
end
PROBE_SPEC

BACKUP=$(mktemp)
cp app/models/commission.rb "$BACKUP"
# Restore the branch file and drop the throwaway spec even if the run dies partway.
trap 'cp "$BACKUP" app/models/commission.rb; rm -f "$BACKUP" "$PROBE"; rm -rf spec/support/fixtures/vcr_cassettes/gp1666_probe' EXIT

echo "########## AFTER (this branch — gate present) ##########"
echo "gate lines in commission.rb: $(grep -c ensure_deposit_is_chargeable app/models/commission.rb)  (want 2)"
PROBE_LEG=_AFTER bundle exec rspec "$PROBE" 2>&1 | grep -E "PROBE_AFTER|examples,"

echo "########## BEFORE (origin/main — gate absent) ##########"
git show origin/main:app/models/commission.rb > app/models/commission.rb
echo "gate lines in commission.rb: $(grep -c ensure_deposit_is_chargeable app/models/commission.rb)  (want 0)"
PROBE_LEG=_BEFORE bundle exec rspec "$PROBE" 2>&1 | grep -E "PROBE_BEFORE|examples,"

cp "$BACKUP" app/models/commission.rb
echo "restored gate lines: $(grep -c ensure_deposit_is_chargeable app/models/commission.rb)  (want 2)"
