# frozen_string_literal: true

module PartnerMigrationsHelper
  BUTTON_CLASS = "inline-flex items-center justify-center gap-2 cursor-pointer border rounded font-[inherit] no-underline disabled:opacity-30 px-4 py-3 text-base leading-snug"

  def partner_migration_button_class(primary: true)
    "#{BUTTON_CLASS} #{primary ? "border-transparent bg-accent-with-text text-accent-foreground" : "border-button bg-background"}"
  end

  def partner_migration_title(migration)
    "Move #{pluralize(migration.catalog_size, "product")} from #{migration.oauth_application.name} to Gumroad?"
  end
end
