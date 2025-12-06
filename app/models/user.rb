class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  has_many :chats
  has_many :recipes, through: :chats

  # Standard allergy list that must be asked when preparing food
  # Stored as a hash with boolean values: { "peanut" => true, "tree_nuts" => false, ... }
  STANDARD_ALLERGIES = %w[
    peanut
    tree_nuts
    sesame
    shellfish
    milk
    egg
    fish
    wheat
    soy
    kiwi
  ].freeze

  # Standard appliance list
  # Stored as a hash with boolean values: { "stove" => true, "oven" => false, ... }
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

  # Treat jsonb appliances column as individual accessors
  store_accessor :appliances, *STANDARD_APPLIANCES

  # Initialize allergies and appliances as empty hash if nil
  before_validation :initialize_allergies, on: :create
  before_validation :initialize_appliances, on: :create

  # Get list of active allergies (where value is true)
  #
  # @return [Array<String>] Array of allergy keys that are active
  def active_allergies
    return [] unless allergies.is_a?(Hash)

    allergies.select { |_key, value| value == true }.keys
  end

  # Check if user has a specific allergy
  #
  # @param allergy_key [String] The allergy key to check (e.g., "peanut")
  # @return [Boolean] True if user has this allergy
  def has_allergy?(allergy_key)
    return false unless allergies.is_a?(Hash)

    allergies[allergy_key.to_s] == true
  end

  # Get human-readable allergy names for display
  #
  # @return [Array<String>] Array of formatted allergy names
  def allergy_names
    active_allergies.map { |key| format_allergy_name(key) }
  end

  # Get list of active appliances (where value is true)
  #
  # @return [Array<String>] Array of appliance keys that are active
  def active_appliances
    return [] unless appliances.is_a?(Hash)

    appliances.select { |_key, value| value == true }.keys
  end

  # Check if user has a specific appliance
  #
  # @param appliance_key [String] The appliance key to check (e.g., "stove")
  # @return [Boolean] True if user has this appliance
  def has_appliance?(appliance_key)
    return false unless appliances.is_a?(Hash)

    appliances[appliance_key.to_s] == true
  end

  # Get human-readable appliance names for display
  #
  # @return [Array<String>] Array of formatted appliance names
  def appliance_names
    active_appliances.map { |key| format_appliance_name(key) }
  end

  private

  # Initialize allergies hash with all standard allergies set to false
  def initialize_allergies
    return if allergies.present?

    self.allergies = STANDARD_ALLERGIES.each_with_object({}) do |allergy, hash|
      hash[allergy] = false
    end
  end

  # Initialize appliances hash with all standard appliances set to false
  def initialize_appliances
    return if appliances.present?

    self.appliances = STANDARD_APPLIANCES.each_with_object({}) do |appliance, hash|
      hash[appliance] = false
    end
  end

  # Format allergy key to human-readable name
  #
  # @param key [String] Allergy key (e.g., "tree_nuts")
  # @return [String] Formatted name (e.g., "Tree nuts")
  def format_allergy_name(key)
    key.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end

  # Format appliance key to human-readable name
  #
  # @param key [String] Appliance key (e.g., "stick_blender")
  # @return [String] Formatted name (e.g., "Stick blender")
  def format_appliance_name(key)
    key.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end
end
