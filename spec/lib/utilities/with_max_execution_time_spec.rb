# frozen_string_literal: true

require "spec_helper"

describe WithMaxExecutionTime do
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
        original_execute = connection.method(:execute)
        call_count = 0

        allow(connection).to receive(:execute).and_wrap_original do |_original, sql, *args|
          call_count += 1
          if call_count > 2 && sql.match?(/\Aset max_execution_time/)
            raise Mysql2::Error, "MySQL server has gone away"
          else
            original_execute.call(sql, *args)
          end
        end

        expect do
          described_class.timeout_queries(seconds: 0.001) do
            raise ActiveRecord::StatementInvalid.new("Mysql2::Error: Query execution was interrupted, maximum statement execution time exceeded")
          end
        end.to raise_error(described_class::QueryTimeoutError)
      end

      it "logs the restoration failure" do
        connection = ActiveRecord::Base.connection
        original_execute = connection.method(:execute)
        call_count = 0

        allow(connection).to receive(:execute).and_wrap_original do |_original, sql, *args|
          call_count += 1
          if call_count > 2 && sql.match?(/\Aset max_execution_time/)
            raise Mysql2::Error, "MySQL server has gone away"
          else
            original_execute.call(sql, *args)
          end
        end

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
