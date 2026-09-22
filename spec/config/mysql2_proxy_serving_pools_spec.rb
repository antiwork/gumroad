# frozen_string_literal: true

require "spec_helper"

describe "mysql2 proxy serving pools" do
  include_context "real mysql2 proxy pools"

  it "honors the application primary identity with a cold and expired write context" do
    expect(@primary.connection_descriptor.name).to eq("ActiveRecord::Base")
    expect(@primary.open_transactions).to eq(0)
    expect(serving_pool).to eq("replica")
    ApplicationRecord.connected_to(role: :writing) { expect(serving_pool).to eq("primary") }
    primary_setup { @primary.execute("UPDATE users SET name = name WHERE id = 0") }
    travel 3.seconds
    ApplicationRecord.connected_to(role: :writing) { expect(serving_pool).to eq("primary") }
    expect(serving_pool).to eq("replica")
  end

  it "preserves both nesting directions and ignores unrelated and roleless stack entries" do
    stub_const("RoutingOtherRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RoutingOtherRecord.connects_to database: { writing: @primary_config, reading: @replica_config }
    [:writing, :reading].each do |outer|
      inner = outer == :writing ? :reading : :writing
      ApplicationRecord.connected_to(role: outer) do
        RoutingOtherRecord.connected_to(role: inner) do
          expect(serving_pool).to eq(outer == :writing ? "primary" : "replica")
          ApplicationRecord.connected_to(shard: :default) do
            expect(serving_pool).to eq(outer == :writing ? "primary" : "replica")
          end
          ApplicationRecord.connected_to(role: inner) { expect(serving_pool).to eq(inner == :writing ? "primary" : "replica") }
          expect(serving_pool).to eq(outer == :writing ? "primary" : "replica")
        end
      end
    end
    ActiveRecord::Base.connected_to(role: :writing) do
      RoutingOtherRecord.connected_to(role: :reading) { expect(serving_pool).to eq("primary") }
    end
  ensure
    [:writing, :reading].each { ActiveRecord::Base.connection_handler.remove_connection_pool("RoutingOtherRecord", role: _1) }
  end

  it "keeps independent reading guards scoped while dispatching application queries" do
    stub_const("RoutingOtherRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    RoutingOtherRecord.connects_to database: { writing: @primary_config, reading: @replica_config }
    RoutingOtherRecord.connected_to(role: :reading) do
      ApplicationRecord.connected_to(role: :writing) do
        expect(serving_pool).to eq("primary")
        expect(RoutingOtherRecord.current_role).to eq(:reading)
        expect { RoutingOtherRecord.connection.execute("UPDATE users SET name = name WHERE id = 0") }.to raise_error(ActiveRecord::ReadOnlyError)
      end
    end
  ensure
    [:writing, :reading].each { ActiveRecord::Base.connection_handler.remove_connection_pool("RoutingOtherRecord", role: _1) }
  end

  it "preserves writing prevent_writes and explicit reading guards at SQL dispatch" do
    [:reading, :writing].each do |role|
      ApplicationRecord.connected_to(role:, prevent_writes: true) do
        expect { ApplicationRecord.connection.execute("UPDATE users SET name = name WHERE id = 0") }.to raise_error(ActiveRecord::ReadOnlyError)
      end
    end
  end

  it "materializes direct relations, leaves wrapped relations lazy, and restores returns and exceptions" do
    user = primary_setup { create(:user) }
    direct = ApplicationRecord.connected_to(role: :writing) { User.where(id: user.id) }
    expect(direct).to be_loaded
    expect(direct.map(&:id)).to eq([user.id])
    wrapped = ApplicationRecord.connected_to(role: :writing) { [User.where(id: user.id)] }
    expect(wrapped.first).not_to be_loaded
    expect(wrapped.first.to_a).to be_empty
    expect(ApplicationRecord.connected_to(role: :writing) { :returned }).to eq(:returned)
    expect { ApplicationRecord.connected_to(role: :writing) { raise "routing exit" } }.to raise_error("routing exit")
    result = catch(:routing_exit) { ApplicationRecord.connected_to(role: :writing) { throw :routing_exit, :returned } }
    expect(result).to eq(:returned)
    expect(ApplicationRecord.connected_to_stack).to be_empty
    expect(serving_pool).to eq("replica")
  end

  it "separates cached replica misses from primary results and restores replica caching" do
    user = primary_setup { create(:user) }
    ApplicationRecord.cache do
      expect(User.where(id: user.id).pluck(:id)).to be_empty
      2.times do
        ApplicationRecord.connected_to(role: :writing) { expect(User.where(id: user.id).pluck(:id)).to eq([user.id]) }
        expect(User.where(id: user.id).pluck(:id)).to be_empty
      end
    end
  end

  it "refreshes stale cached values across pins while retaining cache and uncached semantics" do
    user = primary_setup { create(:user, name: "Old name") }
    replicate_record(user)
    primary_setup { user.update!(name: "New name") }
    hits = []
    subscriber = ->(*, payload) { hits << payload[:cached] if payload[:sql].include?("`users`.`name`") }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      ApplicationRecord.cache do
        2.times { expect(User.where(id: user.id).pick(:name)).to eq("Old name") }
        ApplicationRecord.connected_to(role: :writing) do
          2.times { expect(User.where(id: user.id).pick(:name)).to eq("New name") }
          ApplicationRecord.uncached { expect(User.where(id: user.id).pick(:name)).to eq("New name") }
        end
        expect(User.where(id: user.id).pick(:name)).to eq("Old name")
      end
    end
    expect(hits).to eq([nil, true, nil, true, nil, nil])
    expect(@primary.query_cache_enabled).to be_falsey
  end

  it "preserves unpinned offloading, transaction and locking reads, and the two second window" do
    expect(serving_pool).to eq("replica")
    @primary.execute("UPDATE users SET name = name WHERE id = 0")
    expect(serving_pool).to eq("primary")
    ApplicationRecord.connected_to(role: :reading) { expect(serving_pool).to eq("replica") }
    travel 3.seconds
    expect(serving_pool).to eq("replica")
    ApplicationRecord.transaction { expect(serving_pool).to eq("primary") }
    cold_write_context
    reads = record_serving_reads { User.lock.where(id: 0).load }
    expect(reads.select { _1.first.include?("FOR UPDATE") }.map(&:last)).to eq(["primary"])
    expect(serving_pool).to eq("replica")
  end

  it "applies and restores distinct physical timeouts through nested scopes and exceptions" do
    @primary.raw_connection.query("SET max_execution_time = 310000")
    @replica.raw_connection.query("SET max_execution_time = 210000")
    ApplicationRecord.connected_to(role: :reading) do
      expect do
        WithMaxExecutionTime.timeout_queries(seconds: 5) do
          expect(@primary.raw_connection.query("SELECT @@max_execution_time", as: :array).first).to eq([5000])
          expect(@replica.raw_connection.query("SELECT @@max_execution_time", as: :array).first).to eq([5000])
          expect(serving_pool).to eq("replica")
          raise "timeout exit"
        end
      end.to raise_error("timeout exit")
      expect(serving_pool).to eq("replica")
    end
    expect(@primary.raw_connection.query("SELECT @@max_execution_time", as: :array).first).to eq([310000])
    expect(@replica.raw_connection.query("SELECT @@max_execution_time", as: :array).first).to eq([210000])
  end
end

describe "mysql2 proxy flag-off web contract" do
  it "keeps application roles on the primary without enabling read protection" do
    expect(ApplicationRecord.replica_roles_configured?).to be(false)
    expect(ApplicationRecord.connection.adapter_name).to eq("Mysql2")
    original_pool = ApplicationRecord.connection_pool
    [:reading, :writing].each do |role|
      ApplicationRecord.connected_to(role:) do
        expect(ApplicationRecord.connection_pool).to equal(original_pool)
        expect(ApplicationRecord.current_preventing_writes).to be(false)
        expect(ApplicationRecord.connection.select_value("SELECT DATABASE()")).to eq(original_pool.db_config.database)
      end
    end
  end
end
