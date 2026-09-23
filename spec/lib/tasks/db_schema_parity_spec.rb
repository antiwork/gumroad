# frozen_string_literal: true

require "spec_helper"

describe "db:schema_parity rake task" do
  before(:all) do
    # Re-loading a .rake file appends a second action to each task, which would make every
    # invocation run twice.
    unless Rake::Task.task_defined?("db:schema_parity")
      Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib", "tasks", "db_schema_parity.rake")
    end
  end

  def run_task
    task = Rake::Task["db:schema_parity"]
    task.reenable
    task.invoke
  end

  def parity_reporting(missing)
    instance_double(DbSchemaParity, missing:)
  end

  describe "db:schema_parity" do
    it "reports a clean schema and raises nothing" do
      allow(DbSchemaParity).to receive(:from_live_connection).and_return(parity_reporting([]))

      expect { run_task }.to output(/the live schema has everything db\/schema.rb declares/).to_stdout
    end

    context "when db/schema.rb declares something the live database does not have" do
      let(:missing) do
        [
          DbSchemaParity::Missing.new(table: "charges", kind: "index", name: "index_charges_on_stripe_payment_intent_id"),
        ]
      end

      before { allow(DbSchemaParity).to receive(:from_live_connection).and_return(parity_reporting(missing)) }

      it "names every missing object in the deploy log" do
        allow(ErrorNotifier).to receive(:notify)

        expect { run_task }.to raise_error(SystemExit).and output(
          /MISSING charges: index index_charges_on_stripe_payment_intent_id/,
        ).to_stdout
      end

      # The deploy script runs this with `|| echo`, so the shell throws the exit status away. If the
      # task swallows the failure too, a live schema short of what schema.rb declares ships with
      # nothing anywhere to read — and no later deploy will repair it.
      it "reports the drift to Sentry" do
        expect(ErrorNotifier).to receive(:notify).with(
          an_instance_of(DbSchemaParity::DriftError),
          exclude_request_context: true,
          task: "db:schema_parity",
        )

        expect { run_task }.to raise_error(SystemExit)
      end

      it "exits non-zero so a direct (non-deploy) run fails loudly" do
        allow(ErrorNotifier).to receive(:notify)

        expect { run_task }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end
    end
  end
end
