# frozen_string_literal: true

require "spec_helper"
require "active_record_proxy_adapters/mysql2_proxy"

# Exercise the installed gem's routing, not a copy of its SQL matchers.
describe ActiveRecordProxyAdapters::Mysql2Proxy do
  let(:primary) { double("primary", open_transactions: 0) }
  let(:routing_proxy) { described_class.new(primary) }

  before do
    allow(routing_proxy).to receive(:connection_class).and_return(ApplicationRecord)
    allow(routing_proxy).to receive(:primary_connection_name).and_return("primary")
    allow(ApplicationRecord).to receive(:connected_to_stack).and_return([])
  end

  around do |example|
    previous = ActiveRecordProxyAdapters::Contextualizer.current_context
    ActiveRecordProxyAdapters::Contextualizer.current_context = ActiveRecordProxyAdapters::Context.new({})
    example.run
  ensure
    ActiveRecordProxyAdapters::Contextualizer.current_context = previous
  end

  def roles(sql)
    routing_proxy.send(:roles_for, sql)
  end

  it "routes ordinary SELECTs to reading and writes and locking reads to writing" do
    expect(roles("SELECT * FROM users")).to eq([:reading])
    expect(roles("UPDATE users SET name = 'example'")).to eq([:writing])
    expect(roles("SELECT * FROM users FOR UPDATE")).to eq([:writing])
    expect(roles("SELECT GET_LOCK('example', 0)")).to eq([:writing])
  end

  it "keeps transactions on writing" do
    allow(primary).to receive(:open_transactions).and_return(1)
    expect(roles("SELECT * FROM users")).to eq([:writing])
  end

  it "pins reads for the configured two-second window, not the whole job" do
    travel_to(Time.current) do
      routing_proxy.send(:update_primary_latest_write_timestamp)
      expect(roles("SELECT * FROM users")).to eq([:writing])
      travel 1.second
      expect(roles("SELECT * FROM users")).to eq([:writing])
      travel 1.second
      expect(roles("SELECT * FROM users")).to eq([:reading])
    end
  end

  it "honors explicit writing even after the stickiness window" do
    allow(ApplicationRecord).to receive(:connected_to_stack).and_return([{ role: :writing, klasses: [ApplicationRecord] }])
    expect(roles("SELECT * FROM users")).to eq([:writing])
  end

  it "broadcasts SET only outside a pin, transaction, or recent write" do
    expect(roles("SET max_execution_time = 5000")).to eq([:reading, :writing])
    routing_proxy.send(:update_primary_latest_write_timestamp)
    expect(roles("SET max_execution_time = 5000")).to eq([:writing])
  end

  it "does not recognize session-variable and LAST_INSERT_ID reads as primary-only" do
    expect(roles("SELECT @@max_execution_time")).to eq([:reading])
    expect(roles("SELECT LAST_INSERT_ID()")).to eq([:reading])
  end

  it "falls back for replica checkout connection errors but not statement errors" do
    pool = double("replica pool")
    allow(routing_proxy).to receive(:replica_pool).and_return(pool)
    allow(pool).to receive(:lease_connection).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect(routing_proxy.send(:checkout_replica_connection)).to eq(primary)
    allow(pool).to receive(:lease_connection).and_raise(ActiveRecord::StatementInvalid)
    expect { routing_proxy.send(:checkout_replica_connection) }.to raise_error(ActiveRecord::StatementInvalid)
  end
end
