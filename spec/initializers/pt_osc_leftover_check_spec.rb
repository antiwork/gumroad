# frozen_string_literal: true

require "spec_helper"

describe PtOscLeftoverCheck do
  let(:leftover) do
    PtOscLeftovers::Leftover.new(
      table: "purchases",
      triggers: %w[pt_osc_gumroad_production_purchases_ins],
      shadow_tables: %w[_purchases_new]
    )
  end

  before do
    # Alterity's state is global; make sure each example starts from "enabled"
    # regardless of what ran before it. `migrating=` is stubbed too because the real
    # before_running_migrations sets it, and the integration examples below call
    # through to it.
    allow(Alterity).to receive(:state).and_return(double(disabled: false, :migrating= => true))

    # The check is deliberately inert in the test environment (a developer's own
    # interrupted pt-osc run must not redden unrelated specs), so switch it on for
    # the examples that are about the check itself.
    allow(described_class).to receive(:enabled?).and_return(true)
  end

  describe "test-environment default" do
    it "is inert in the RSpec suite unless explicitly switched on" do
      allow(described_class).to receive(:enabled?).and_call_original
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect { described_class.run! }.not_to raise_error
    end

    it "runs when PT_OSC_LEFTOVER_CHECK_IN_TESTS is set" do
      allow(described_class).to receive(:enabled?).and_call_original
      stub_const("ENV", ENV.to_hash.merge("PT_OSC_LEFTOVER_CHECK_IN_TESTS" => "1"))
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect { described_class.run! }.to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end
  end

  describe ".run!" do
    it "does nothing when there are no leftovers" do
      allow(PtOscLeftovers).to receive(:all).and_return([])

      expect { described_class.run! }.not_to raise_error
    end

    it "raises with the operator explanation when leftovers are present" do
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect { described_class.run! }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent, /purchases/)
    end

    it "refuses to migrate rather than letting pt-osc fail obscurely later" do
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect { described_class.run! }.to raise_error(
        PtOscLeftoverCheck::LeftoversPresent, /pt-online-schema-change cannot create triggers that already exist/
      )
    end

    it "warns but does not block on a shadow table with no triggers" do
      # pt-osc renames around a stray shadow table, so refusing to deploy over one
      # would block a migration that would have succeeded.
      shadow_only = PtOscLeftovers::Leftover.new(
        table: "purchases", triggers: [], shadow_tables: %w[_purchases_new]
      )
      allow(PtOscLeftovers).to receive(:all).and_return([shadow_only])

      expect(described_class).to receive(:warn).with(/no leftover triggers/)
      expect { described_class.run! }.not_to raise_error
    end

    it "still blocks when one table has triggers and another has only a shadow table" do
      shadow_only = PtOscLeftovers::Leftover.new(
        table: "users", triggers: [], shadow_tables: %w[_users_new]
      )
      allow(PtOscLeftovers).to receive(:all).and_return([leftover, shadow_only])

      expect { described_class.run! }.to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end

    it "can be bypassed for a deploy that knowingly runs alongside a live pt-osc" do
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      stub_const("ENV", ENV.to_hash.merge("ALLOW_PT_OSC_LEFTOVERS" => "1"))

      expect { described_class.run! }.not_to raise_error
    end

    it "warns but does not block when Alterity is disabled" do
      # With Alterity off the migration is a plain ALTER, which the leftover
      # triggers do not block -- but they are still duplicating every write, and
      # this is the one moment somebody reads the output.
      allow(Alterity).to receive(:state).and_return(double(disabled: true, :migrating= => true))
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect(described_class).to receive(:warn).with(/Alterity is disabled/)
      expect { described_class.run! }.not_to raise_error
    end

    it "continues when information_schema cannot be read" do
      # A check that cannot run must never be the reason a deploy fails.
      allow(PtOscLeftovers).to receive(:all).and_raise(ActiveRecord::StatementInvalid, "nope")

      expect(described_class).to receive(:warn).with(/Could not check for pt-osc leftovers/)
      expect { described_class.run! }.not_to raise_error
    end
  end

  describe "Alterity integration" do
    it "runs the check before Alterity runs migrations" do
      # The check is attached to before_running_migrations so it covers every entry
      # point that migrates through Alterity, not just the deploy's rake task.
      allow(Alterity).to receive(:set_database_config)
      allow(Alterity).to receive(:prepare_replicas_dsns_table)

      expect(described_class).to receive(:run!)

      Alterity.before_running_migrations
    end

    it "aborts before Alterity touches the database when leftovers are present" do
      allow(PtOscLeftovers).to receive(:all).and_return([leftover])

      expect(Alterity).not_to receive(:prepare_replicas_dsns_table)

      expect { Alterity.before_running_migrations }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end
  end
end
