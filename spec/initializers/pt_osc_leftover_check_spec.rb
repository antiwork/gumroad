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
    # Alterity's state is global; start each example from "enabled". `migrating=` is
    # stubbed because the real before_running_migrations sets it.
    allow(Alterity).to receive(:state).and_return(double(disabled: false, :migrating= => true))
    allow(described_class).to receive(:enabled?).and_return(true)
    allow(described_class).to receive(:warn)
  end

  after { described_class.reset! }

  def find_leftovers(*leftovers)
    allow(PtOscLeftovers).to receive(:all).and_return(leftovers)
    described_class.run!
  end

  describe "test-environment default" do
    it "is inert in the RSpec suite unless explicitly switched on" do
      allow(described_class).to receive(:enabled?).and_call_original
      find_leftovers(leftover)

      expect { described_class.check_statement!("ALTER TABLE purchases ADD COLUMN x int") }.not_to raise_error
    end

    it "runs when PT_OSC_LEFTOVER_CHECK_IN_TESTS is set" do
      allow(described_class).to receive(:enabled?).and_call_original
      stub_const("ENV", ENV.to_hash.merge("PT_OSC_LEFTOVER_CHECK_IN_TESTS" => "1"))
      find_leftovers(leftover)

      expect { described_class.check_statement!("ALTER TABLE purchases ADD COLUMN x int") }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end
  end

  describe ".run!" do
    it "does nothing when there are no leftovers" do
      expect(described_class).not_to receive(:warn)

      expect { find_leftovers }.not_to raise_error
    end

    it "warns about every leftover without refusing to migrate" do
      expect(described_class).to receive(:warn).with(/purchases.*refused while the triggers exist/m)

      expect { find_leftovers(leftover) }.not_to raise_error
    end

    it "continues when information_schema cannot be read" do
      allow(PtOscLeftovers).to receive(:all).and_raise(ActiveRecord::StatementInvalid, "nope")

      expect(described_class).to receive(:warn).with(/Could not check for pt-osc leftovers/)
      expect { described_class.run! }.not_to raise_error
      expect { described_class.check_statement!("ALTER TABLE purchases ADD COLUMN x int") }.not_to raise_error
    end
  end

  describe ".check_statement!" do
    before { find_leftovers(leftover) }

    [
      "ALTER TABLE `purchases` ADD COLUMN x int",
      "ALTER TABLE purchases ADD COLUMN x int, ALGORITHM=INSTANT",
      "CREATE INDEX index_purchases_on_x ON `purchases` (x)",
      "DROP INDEX index_purchases_on_x ON purchases",
      "RENAME TABLE purchases TO purchases_archive",
      "TRUNCATE TABLE purchases",
      "  alter table gumroad_test.purchases drop column x",
      "-- widen\n/* note */ ALTER TABLE purchases MODIFY x bigint",
    ].each do |sql|
      it "refuses #{sql.strip.inspect}" do
        expect { described_class.check_statement!(sql) }.to raise_error(PtOscLeftoverCheck::LeftoversPresent, /purchases/)
      end
    end

    it "names the triggers in the refusal" do
      expect { described_class.check_statement!("ALTER TABLE purchases ADD COLUMN x int") }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent, /pt_osc_gumroad_production_purchases_ins/)
    end

    [
      "ALTER TABLE users ADD COLUMN x int",
      "ALTER TABLE purchases_archive ADD COLUMN x int",
      "ALTER TABLE `_purchases_new` ADD COLUMN x int",
      "CREATE TABLE purchase_notes (id bigint, purchases_count int)",
      "UPDATE purchases SET flags = 0 WHERE id = 1",
      "INSERT INTO purchases (id) VALUES (1)",
      "DROP TRIGGER pt_osc_gumroad_production_purchases_ins",
      "DROP TABLE `_purchases_new`",
    ].each do |sql|
      it "allows #{sql.inspect}" do
        expect { described_class.check_statement!(sql) }.not_to raise_error
      end
    end

    it "does not refuse a table that has only a shadow table" do
      find_leftovers(PtOscLeftovers::Leftover.new(table: "users", triggers: [], shadow_tables: %w[_users_new]))

      expect { described_class.check_statement!("ALTER TABLE users ADD COLUMN x int") }.not_to raise_error
    end
  end

  describe "Alterity integration" do
    it "runs the check before Alterity runs migrations" do
      allow(Alterity).to receive(:set_database_config)
      allow(Alterity).to receive(:prepare_replicas_dsns_table)
      allow(described_class).to receive(:run!)

      Alterity.before_running_migrations

      expect(described_class).to have_received(:run!)
    end

    it "forgets the tables once Alterity stops migrating" do
      find_leftovers(leftover)

      Alterity.after_running_migrations

      expect { described_class.check_statement!("ALTER TABLE purchases ADD COLUMN x int") }.not_to raise_error
    end

    it "refuses an ALTER on a table with triggers before pt-osc or InstantDdlFirst sees it" do
      find_leftovers(leftover)

      expect(InstantDdlFirst).not_to receive(:attempt)
      expect { Alterity.process_sql_query("ALTER TABLE `purchases` ADD COLUMN x int") { raise "executed" } }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end

    it "refuses it inside Alterity.disable, where migrations run plain ALTERs" do
      allow(Alterity).to receive(:state).and_return(double(disabled: true, :migrating= => true))
      find_leftovers(leftover)

      expect { Alterity.process_sql_query("ALTER TABLE purchases ADD COLUMN x int, ALGORITHM=INSTANT") { raise "executed" } }
        .to raise_error(PtOscLeftoverCheck::LeftoversPresent)
    end

    it "hands schema changes to other tables to Alterity as usual" do
      find_leftovers(leftover)

      expect(InstantDdlFirst).to receive(:attempt).with("users", "ADD COLUMN x int").and_return(true)

      Alterity.process_sql_query("ALTER TABLE users ADD COLUMN x int") { raise "executed" }
    end
  end
end
