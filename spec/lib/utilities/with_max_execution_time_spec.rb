# frozen_string_literal: true

require "spec_helper"

describe WithMaxExecutionTime do
  def simulate_max_execution_time_restore_failure(connection)
    set_max_execution_time_calls = 0

    allow(connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      if sql.start_with?("set max_execution_time")
        set_max_execution_time_calls += 1
        raise Mysql2::Error, "MySQL server has gone away" if set_max_execution_time_calls > 1

        nil
      else
        original.call(sql, *args)
      end
    end
  end

  describe ".timeout_queries" do
    it "raises Timeout error if query took longer than allowed" do
      # Note: MySQL max_execution_time ignores SLEEP(), so we have to manufacture a real slow query.
      create(:user)
      slow_query = "select * from users " + 50.times.map { |i| "join users u#{i}" }.join(" ")
      expect do
        described_class.timeout_queries(seconds: 0.001) do
          ActiveRecord::Base.connection.execute(slow_query)
        end
      end.to raise_error(described_class::QueryTimeoutError)
    end

    it "returns block value if no error occurred" do
      returned_value = described_class.timeout_queries(seconds: 5) do
        ActiveRecord::Base.connection.execute("select 1")
        :foo
      end
      expect(returned_value).to eq(:foo)
    end

    context "when restoring max_execution_time fails" do
      it "does not mask QueryTimeoutError from the caller" do
        connection = ActiveRecord::Base.connection
        simulate_max_execution_time_restore_failure(connection)

        expect do
          described_class.timeout_queries(seconds: 0.001) do
            raise ActiveRecord::StatementInvalid.new("Mysql2::Error: Query execution was interrupted, maximum statement execution time exceeded")
          end
        end.to raise_error(described_class::QueryTimeoutError)
      end

      it "logs the restoration failure" do
        connection = ActiveRecord::Base.connection
        simulate_max_execution_time_restore_failure(connection)

        expect(Rails.logger).to receive(:error).with(/\[WithMaxExecutionTime\] Failed to restore max_execution_time.*MySQL server has gone away/)

        expect do
          described_class.timeout_queries(seconds: 0.001) do
            raise ActiveRecord::StatementInvalid.new("Mysql2::Error: Query execution was interrupted, maximum statement execution time exceeded")
          end
        end.to raise_error(described_class::QueryTimeoutError)
      end
    end
  end
end
