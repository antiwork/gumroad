# frozen_string_literal: true

# Creates the email engagement table on the DynamoDB Local container. The
# test suite reads and writes DynamoDB for real, so an unreachable endpoint
# is fatal. The test_ prefix keeps the suite off lane 0's dev table; examples
# stay isolated from each other because engagement partitions are keyed by
# installment id and every example creates fresh installments.
class DynamodbSetup
  def self.prepare_test_environment
    attempts = 0
    begin
      EmailEngagementDynamoStore.create_table!
    rescue Aws::DynamoDB::Errors::ResourceInUseException
      nil
    rescue Seahorse::Client::NetworkingError
      attempts += 1
      if attempts < 5
        sleep 1
        retry
      end
      raise "Could not reach DynamoDB at #{EmailEngagementDynamoStore.client.config.endpoint} " \
            "to create #{EmailEngagementDynamoStore.table_name}. " \
            "Start the dynamodb docker compose service (`make local`)."
    end
  end
end
