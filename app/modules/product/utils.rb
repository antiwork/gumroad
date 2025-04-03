# frozen_string_literal: true

module Product::Utils
  extend ActiveSupport::Concern

  class_methods do
    # Helper for when debugging in console.
    #
    # Fetches a product uniquely identified by `id_or_permalink` (ID, unique or custom permalink)
    # and optionally scoped by `user_id` if more than one product can be matched via custom permalink.
    def f(id_or_permalink, user_id = nil)
      Link.find_by_unique_permalink(id_or_permalink) || find_unique_by(user_id, custom_permalink: id_or_permalink) || Link.find(id_or_permalink)
    end

    private
      # May be simplified/replaced with https://edgeapi.rubyonrails.org/classes/ActiveRecord/FinderMethods.html#method-i-find_sole_by once we upgrade to Rails 7
      def find_unique_by(user_id, **args)
        found, undesired = Link.by_user(user_id && User.find(user_id)).where(args).first(2)
        raise ActiveRecord::RecordNotUnique, "More than one product matched" if undesired.present?

        found
      end
  end
end
