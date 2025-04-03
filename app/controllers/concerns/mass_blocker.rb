# frozen_string_literal: true

module MassBlocker
  extend ActiveSupport::Concern

  # Records can be separated by whitespaces or commas
  DELIMITER_REGEX = /\s|,/
  BATCH_SIZE = 1_000

  private
    def schedule_mass_block(identifiers:, object_type:, expires_in: nil)
      array_of_mass_block_args = identifiers.split(DELIMITER_REGEX)
                                            .select(&:present?)
                                            .uniq
                                            .map { |identifier| [object_type, identifier, logged_in_user.id, expires_in].compact }

      array_of_mass_block_args.in_groups_of(BATCH_SIZE, false).each do |array_of_args|
        BlockObjectWorker.perform_bulk(array_of_args, batch_size: BATCH_SIZE)
      end
    end
end
