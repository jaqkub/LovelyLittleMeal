class ChangeAppliancesToJsonb < ActiveRecord::Migration[7.1]
  # Standard appliance list
  # Note: stove implies pan, so pan is not in the list
  STANDARD_APPLIANCES = %w[
    stove
    oven
    microwave
    blender
    stick_blender
    mixer
    kettle
    toaster
    air_fryer
    pressure_cooker
  ].freeze

  # Mapping from old appliance names to new names
  OLD_TO_NEW_MAPPING = {
    "pan" => "stove", # pan is implied by stove
    "fryer" => "air_fryer",
    "food_processor" => "blender"
  }.freeze

  def up
    # First, add a temporary column for jsonb
    add_column :users, :appliances_jsonb, :jsonb, default: {}

    # Migrate existing data: convert comma-separated strings to hash format
    User.reset_column_information
    User.find_each do |user|
      # Parse existing appliances (could be string, array, or already hash)
      existing_appliances = if user.appliances.blank?
                               {}
                             elsif user.appliances.is_a?(Hash)
                               user.appliances
                             elsif user.appliances.is_a?(Array)
                               # Convert array to hash
                               existing_appliances_array = user.appliances.map(&:to_s).map(&:strip).map(&:downcase)
                               existing_appliances_array.each_with_object({}) do |appliance, hash|
                                 mapped_appliance = map_old_appliance_to_new(appliance)
                                 hash[mapped_appliance] = true if mapped_appliance
                               end
                             elsif user.appliances.is_a?(String)
                               # Convert comma-separated string to hash
                               appliance_array = user.appliances.split(",").map(&:strip).map(&:downcase)
                               appliance_array.each_with_object({}) do |appliance, hash|
                                 mapped_appliance = map_old_appliance_to_new(appliance)
                                 hash[mapped_appliance] = true if mapped_appliance
                               end
                             else
                               {}
                             end

      # Initialize hash with all standard appliances set to false
      new_appliances = STANDARD_APPLIANCES.each_with_object({}) do |appliance, hash|
        hash[appliance] = existing_appliances[appliance] || existing_appliances[appliance.to_sym] || false
      end

      user.update_column(:appliances_jsonb, new_appliances)
    end

    # Remove old column and rename new one
    remove_column :users, :appliances
    rename_column :users, :appliances_jsonb, :appliances

    # Add index for jsonb queries
    add_index :users, :appliances, using: :gin
  end

  def down
    # Remove index
    remove_index :users, :appliances if index_exists?(:users, :appliances)

    # Add temporary text column
    add_column :users, :appliances_text, :text

    # Convert hash back to comma-separated string
    User.reset_column_information
    User.find_each do |user|
      next unless user.appliances.is_a?(Hash)

      # Get all appliances that are true
      active_appliances = user.appliances.select { |_key, value| value == true }.keys
      user.update_column(:appliances_text, active_appliances.join(", "))
    end

    # Remove jsonb column and rename text column
    remove_column :users, :appliances
    rename_column :users, :appliances_text, :appliances
  end

  private

  # Maps old appliance names to new standard appliance names
  def map_old_appliance_to_new(old_appliance)
    old_lower = old_appliance.downcase.strip

    # Direct matches
    return old_lower if STANDARD_APPLIANCES.include?(old_lower)

    # Mapping for old appliance names
    OLD_TO_NEW_MAPPING[old_lower] || old_lower
  end
end
