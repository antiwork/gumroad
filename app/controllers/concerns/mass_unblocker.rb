# frozen_string_literal: true

module MassUnblocker
  extend ActiveSupport::Concern

  private
    def schedule_mass_unblock(identifiers:)
      array_of_mass_unblock_args = identifiers.split(MassBlocker::DELIMITER_REGEX)
                                            .select(&:present?)
                                            .uniq
                                            .map { |identifier| [identifier] }
      array_of_mass_unblock_args.in_groups_of(MassBlocker::BATCH_SIZE, false).each do |array_of_args|
        UnblockObjectWorker.perform_bulk(array_of_args, batch_size: MassBlocker::BATCH_SIZE)
      end
    end
end
