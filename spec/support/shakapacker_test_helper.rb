# frozen_string_literal: true

# In test, gracefully ignore missing pack entries (like email.css) to avoid failing specs
# due to frontend asset compilation not including optional packs.
if defined?(Shakapacker) && defined?(Shakapacker::Helper)
  Shakapacker::Helper.module_eval do
    unless method_defined?(:stylesheet_pack_tag_without_rescue)
      alias_method :stylesheet_pack_tag_without_rescue, :stylesheet_pack_tag

      def stylesheet_pack_tag(*names, **options)
        stylesheet_pack_tag_without_rescue(*names, **options)
      rescue Shakapacker::Manifest::MissingEntryError
        "".html_safe
      end
    end
  end
end

