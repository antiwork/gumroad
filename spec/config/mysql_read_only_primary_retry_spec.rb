# frozen_string_literal: true

require "spec_helper"

RSpec.describe MysqlReadOnlyPrimaryRetry do
  let(:config) { ActiveRecord::Base.connection_db_config.configuration_hash }
  # Outside the pool so the fixture transaction does not wrap these statements.
  let(:adapter) { ActiveRecord::ConnectionAdapters::Mysql2Adapter.new(config) }
  let(:read_only_error) do
    Mysql2::Error.new("The MySQL server is running with the --read-only option so it cannot execute this statement", nil, 1290)
  end
  let(:failures) { [] }

  def fail_queries_with(error, times:, matching: /\AINSERT/)
    remaining = times
    allow_any_instance_of(Mysql2::Client).to receive(:query).and_wrap_original do |original, sql, *args|
      if matching.match?(sql) && remaining > 0
        remaining -= 1
        failures << original.receiver
        raise error
      end
      original.call(sql, *args)
    end
  end

  def probe_ids
    adapter.select_values("SELECT id FROM read_only_retry_probe")
  end

  before do
    stub_const("MysqlReadOnlyPrimaryRetry::RETRY_BACKOFF", 0)
    adapter.execute("DROP TABLE IF EXISTS read_only_retry_probe")
    adapter.execute("CREATE TABLE read_only_retry_probe (id int)")
  end

  after do
    RSpec::Mocks.space.proxy_for(Mysql2::Client).reset
    adapter.execute("DROP TABLE IF EXISTS read_only_retry_probe")
    adapter.disconnect!
  end

  it "reconnects and runs the write once more on a fresh connection" do
    fail_queries_with(read_only_error, times: 1)

    adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)")

    expect(probe_ids).to eq([1])
    expect(failures.size).to eq(1)
    retried_on = adapter.instance_variable_get(:@raw_connection)
    expect(retried_on).not_to equal(failures.first)

    adapter._run_checkin_callbacks { }
    expect(adapter.instance_variable_get(:@raw_connection)).to equal(retried_on)
  end

  it "retries only once and drops the connection at checkin" do
    fail_queries_with(read_only_error, times: 2)

    expect { adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)") }
      .to raise_error(ActiveRecord::StatementInvalid, /--read-only/)
    expect(failures.size).to eq(2)

    adapter._run_checkin_callbacks { }
    expect(adapter.instance_variable_get(:@raw_connection)).to be_nil
    expect(probe_ids).to eq([])
  end

  it "covers the mysql2_proxy primary adapter" do
    require "active_record/connection_adapters/mysql2_proxy_adapter"

    expect(ActiveRecord::ConnectionAdapters::Mysql2ProxyAdapter.ancestors).to include(described_class)
  end

  it "does not retry inside a transaction and drops the connection at checkin" do
    fail_queries_with(read_only_error, times: 1)

    expect do
      adapter.transaction { adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)") }
    end.to raise_error(ActiveRecord::StatementInvalid, /--read-only/)
    expect(failures.size).to eq(1)
    expect(adapter.instance_variable_get(:@raw_connection)).to equal(failures.first)

    adapter._run_checkin_callbacks { }

    expect(adapter.instance_variable_get(:@raw_connection)).to be_nil
    expect(probe_ids).to eq([])
  end

  it "does not retry on a replica connection" do
    replica = ActiveRecord::ConnectionAdapters::Mysql2Adapter.new(config.merge(replica: true))
    fail_queries_with(read_only_error, times: 1, matching: /\ASELECT GET_LOCK/)

    expect { replica.execute("SELECT GET_LOCK('read_only_retry_probe', 0)") }
      .to raise_error(ActiveRecord::StatementInvalid, /--read-only/)
    expect(failures.size).to eq(1)
  ensure
    replica&.disconnect!
  end

  it "leaves other errors untouched, including 1290 for other server options" do
    fail_queries_with(Mysql2::Error.new("The MySQL server is running with the --secure-file-priv option so it cannot execute this statement", nil, 1290), times: 1)
    expect { adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)") }
      .to raise_error(ActiveRecord::StatementInvalid, /--secure-file-priv/)

    fail_queries_with(Mysql2::Error.new("Duplicate entry '1' for key 'PRIMARY'", nil, 1062), times: 1)
    expect { adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)") }
      .to raise_error(ActiveRecord::RecordNotUnique)

    expect(failures.size).to eq(2)
    expect(probe_ids).to eq([])
  end

  it "raises the original error when the reconnect fails" do
    fail_queries_with(read_only_error, times: 1)
    allow(adapter).to receive(:reconnect!).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect { adapter.execute("INSERT INTO read_only_retry_probe (id) VALUES (1)") }
      .to raise_error(ActiveRecord::StatementInvalid, /--read-only/)
  end
end
