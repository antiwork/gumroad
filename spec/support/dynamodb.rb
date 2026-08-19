# frozen_string_literal: true

# Creates the email engagement table on the DynamoDB Local container so specs
# can run against a real endpoint. An unreachable DynamoDB only warns for now:
# no spec depends on a live table yet (EmailEngagementDynamoStore's specs stub
# the client). When reads flip and integration specs land, make this raise and
# give the suite its own table: dev and test currently share the container's
# unprefixed one, so per-example cleanup here would wipe lane 0's dev data.
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
      warn "[DynamoDB] Could not reach #{EmailEngagementDynamoStore.client.config.endpoint}; " \
           "the #{EmailEngagementDynamoStore.table_name} table was not created. " \
           "Start the dynamodb docker compose service (`make local`)."
    end
  end
end
