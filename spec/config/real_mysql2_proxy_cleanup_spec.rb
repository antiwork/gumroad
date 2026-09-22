# frozen_string_literal: true

require "spec_helper"

describe "real mysql2 proxy fixture cleanup" do
  self.use_transactional_tests = false

  before do
    @original_database = ActiveRecord::Base.connection_db_config.configuration_hash
    @original_flag = ENV["USE_DB_WORKER_REPLICAS"]
    @original_class = ApplicationRecord.connection_class?
    @original_context = ActiveRecordProxyAdapters::Contextualizer.current_context
    @inspection_client = Mysql2::Client.new(**@original_database.slice(:host, :port, :username, :password))
    stub_const("CleanupOtherRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    CleanupOtherRecord.establish_connection(@original_database)
    @other_pool = CleanupOtherRecord.connection_pool
    @other_context = ActiveRecordProxyAdapters::Context.new({})
    ActiveRecordProxyAdapters::Contextualizer.current_context = @other_context
    @pool_group = Class.new(self.class) { include_context "real mysql2 proxy pools" }
    @fixture = @pool_group.new
    run_pool_hook(:before)
    @databases = @fixture.instance_variable_get(:@routing_databases)
    @schema_client = @fixture.instance_variable_get(:@schema_client)
  end

  after do
    # Failed teardown is the subject of these examples; restore independently after mocks expire.
    ActiveRecord::Base.connection_handler.remove_connection_pool("ActiveRecord::Base", role: :reading)
    ActiveRecord::Base.establish_connection(@original_database)
    ApplicationRecord.connection_class = @original_class
    ENV["USE_DB_WORKER_REPLICAS"] = @original_flag
    @databases&.each { @inspection_client.query("DROP DATABASE IF EXISTS `#{_1}`") }
    @schema_client.close if @schema_client && !@schema_client.closed?
    @inspection_client&.close
    CleanupOtherRecord.remove_connection
    ActiveRecordProxyAdapters::Contextualizer.current_context = @original_context
  end

  def run_pool_hook(position)
    # Call the registered block directly so RSpec's reporter does not consume the expected error.
    @pool_group.hooks.send(:all_hooks_for, position, :context).each { @fixture.instance_exec(&_1.block) }
  end

  def expect_restored_state(remaining_databases: [])
    expect(ENV["USE_DB_WORKER_REPLICAS"]).to eq(@original_flag)
    expect(ApplicationRecord.connection_class?).to eq(@original_class)
    expect(@schema_client).to be_closed
    expect(@inspection_client.query("SHOW DATABASES").map { _1.values.first } & @databases).to eq(remaining_databases)
    expect(CleanupOtherRecord.connection_pool).to equal(@other_pool)
    expect(CleanupOtherRecord.connection.select_value("SELECT DATABASE()")).to eq(@original_database.fetch(:database))
    expect(ActiveRecordProxyAdapters::Contextualizer.current_context).to equal(@other_context)
  end

  it "reconnects and finishes cleanup when reading pool removal raises" do
    error = RuntimeError.new("injected pool removal failure")
    RSpec::Mocks.with_temporary_scope do
      allow(ActiveRecord::Base.connection_handler).to receive(:remove_connection_pool).with("ActiveRecord::Base", role: :reading).and_raise(error)
      expect { run_pool_hook(:after) }.to raise_error { expect(_1).to equal(error) }
      expect(ActiveRecord::Base.connection.select_value("SELECT DATABASE()")).to eq(@original_database.fetch(:database))
      expect_restored_state
    end
  end

  it "restores flags and releases schemas and client when reconnection raises" do
    error = RuntimeError.new("injected reconnection failure")
    RSpec::Mocks.with_temporary_scope do
      allow(ActiveRecord::Base).to receive(:establish_connection).with(@original_database).and_raise(error)
      expect { run_pool_hook(:after) }.to raise_error { expect(_1).to equal(error) }
      expect_restored_state
    end
  end

  it "attempts the other schema and closes the client when a database drop raises" do
    error = RuntimeError.new("injected database drop failure")
    RSpec::Mocks.with_temporary_scope do
      allow(@schema_client).to receive(:query).and_call_original
      allow(@schema_client).to receive(:query).with("DROP DATABASE IF EXISTS `#{@databases.first}`").and_raise(error)
      expect { run_pool_hook(:after) }.to raise_error { expect(_1).to equal(error) }
      expect_restored_state(remaining_databases: [@databases.first])
    end
  end

  it "preserves the first exception while attempting every later cleanup step" do
    error = RuntimeError.new("original removal failure")
    RSpec::Mocks.with_temporary_scope do
      allow(ActiveRecord::Base.connection_handler).to receive(:remove_connection_pool).with("ActiveRecord::Base", role: :reading).and_raise(error)
      expect(ActiveRecord::Base).to receive(:establish_connection).with(@original_database).and_raise("secondary reconnection failure")
      allow(@schema_client).to receive(:query).and_call_original
      allow(@schema_client).to receive(:query).with("DROP DATABASE IF EXISTS `#{@databases.first}`").and_raise("secondary drop failure")
      expect(@schema_client).to receive(:close).and_wrap_original do |original|
        original.call
        raise "secondary close failure"
      end
      expect { run_pool_hook(:after) }.to raise_error { expect(_1).to equal(error) }
      expect_restored_state(remaining_databases: [@databases.first])
    end
  end
end
