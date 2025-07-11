class AddIconColorToSocialProofWidgets < ActiveRecord::Migration[7.1]
  def change
    add_column :social_proof_widgets, :icon_color, :string

    # Get the list of valid icon names from the filesystem
    icons_path = Rails.root.join('app', 'assets', 'images', 'icons')
    valid_icons = if Dir.exist?(icons_path)
      Dir.entries(icons_path)
         .select { |file| file.end_with?('.svg') }
         .map { |file| file.chomp('.svg') }
         .sort
    else
      []
    end

    # Add check constraint for valid icon names
    if valid_icons.any?
      check_constraint = valid_icons.map { |icon| "'#{icon}'" }.join(', ')
      execute <<-SQL
        ALTER TABLE social_proof_widgets
        ADD CONSTRAINT check_valid_icon_names
        CHECK (icon_name IS NULL OR icon_name IN (#{check_constraint}))
      SQL
    end
  end
end
