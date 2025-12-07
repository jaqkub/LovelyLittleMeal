class ChangeAppliancesToJsonb < ActiveRecord::Migration[7.1]
  def up
    # Change appliances column from text to jsonb
    # Since database was reset, no data migration needed - just change the type
    # Handle empty/null values by defaulting to empty jsonb object
    change_column :users, :appliances, :jsonb, default: {}, using: "COALESCE(NULLIF(appliances, ''), '{}')::jsonb"

    # Add index for jsonb queries
    add_index :users, :appliances, using: :gin
  end

  def down
    # Remove index
    remove_index :users, :appliances if index_exists?(:users, :appliances)

    # Convert jsonb back to text
    change_column :users, :appliances, :text, using: 'appliances::text'
  end
end
