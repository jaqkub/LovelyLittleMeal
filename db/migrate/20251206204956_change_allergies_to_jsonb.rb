class ChangeAllergiesToJsonb < ActiveRecord::Migration[7.1]
  def up
    # Change allergies column from text to jsonb
    # Since database was reset, no data migration needed - just change the type
    # Handle empty/null values by defaulting to empty jsonb object
    change_column :users, :allergies, :jsonb, default: {}, using: "COALESCE(NULLIF(allergies, ''), '{}')::jsonb"

    # Add index for jsonb queries
    add_index :users, :allergies, using: :gin
  end

  def down
    # Remove index
    remove_index :users, :allergies if index_exists?(:users, :allergies)

    # Convert jsonb back to text
    change_column :users, :allergies, :text, using: 'allergies::text'
  end
end
