require "async"

# Orchestrator service for running all recipe validations in parallel
# Uses Async gem to execute validations concurrently, improving performance
#
# This service aggregates all validation tools and runs them in parallel,
# then combines the results into a single validation result
#
# Performance benefit: Instead of running validations sequentially (which can take
# 5-10 seconds total), we run them in parallel (taking only as long as the slowest one)
#
# Reference: https://rubyllm.com/async/ for Async patterns
class RecipeValidator
  # Runs all validations in parallel and aggregates results
  #
  # @param recipe_data [Hash] The recipe data to validate
  # @param user [User] The current user (for preferences, allergies, appliances)
  # @param user_message [Message] The user message (for allergen warning validation)
  # @param requested_ingredients [Array<String>] Extracted requested ingredients from user message
  # @param available_appliances [Array<String>] User's available appliances
  # @param unavailable_appliances [Array<String>] User's unavailable appliances
  # @param user_allergies [Array<String>] User's active allergies
  # @return [Hash] Aggregated validation results with all violations and fix instructions
  def self.validate_all(
    recipe_data:,
    user:,
    user_message:,
    requested_ingredients: [],
    available_appliances: [],
    unavailable_appliances: [],
    user_allergies: []
  )
    Async do |task|
      # Run all validations in parallel
      # Each validation runs in its own async task
      results = {}

      # Allergen warning validation (pure Ruby - fast)
      task.async do
        results[:allergen_warning] = validate_allergen_warnings(
          recipe_data,
          user_message,
          requested_ingredients,
          user_allergies
        )
      end

      # Ingredient allergy check (pure Ruby - fast)
      task.async do
        results[:ingredient_allergy] = validate_ingredient_allergies(
          recipe_data,
          user_allergies,
          user_message
        )
      end

      # Metric unit validation (pure Ruby - fast)
      task.async do
        results[:metric_unit] = validate_metric_units(recipe_data)
      end

      # Appliance compatibility check (LLM - slower)
      task.async do
        results[:appliance] = validate_appliance_compatibility(
          recipe_data,
          available_appliances,
          unavailable_appliances
        )
      end

      # Recipe completeness check (LLM - slower)
      task.async do
        results[:completeness] = validate_recipe_completeness(recipe_data)
      end

      # Preference compliance check (LLM - slower)
      task.async do
        results[:preference] = validate_preference_compliance(recipe_data, user)
      end

      # Wait for all validations to complete
      # Async automatically waits for all tasks to finish
    end

    # Aggregate all results
    aggregated = aggregate_results(results)
    
    # Also return individual results for cases where we need specific data (e.g., converted_data from metric unit validator)
    aggregated[:individual_results] = results
    aggregated
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Error during parallel validation: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    # Return empty result if validation fails (don't block recipe generation)
    {
      valid: true,
      violations: [],
      fix_instructions: []
    }
  end

  private

  # Validates allergen warnings
  #
  # @param recipe_data [Hash] Recipe data
  # @param user_message [Message] User message
  # @param requested_ingredients [Array<String>] Extracted requested ingredients
  # @param user_allergies [Array<String>] User's active allergies
  # @return [ValidationResult] Validation result
  def self.validate_allergen_warnings(recipe_data, user_message, requested_ingredients, user_allergies)
    # Extract instructions from response
    instructions = recipe_data.dig("content", "instructions") || []

    # Validate
    Tools::AllergenWarningValidator.validate(
      instructions: instructions,
      requested_ingredients: requested_ingredients,
      user_allergies: user_allergies
    )
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Allergen warning validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Validates ingredient allergies
  #
  # @param recipe_data [Hash] Recipe data
  # @param user_allergies [Array<String>] User's active allergies
  # @param user_message [Message] User message
  # @return [ValidationResult] Validation result
  def self.validate_ingredient_allergies(recipe_data, user_allergies, user_message)
    ingredients = recipe_data.dig("content", "ingredients") || []

    Tools::IngredientAllergyChecker.validate(
      ingredients: ingredients,
      user_allergies: user_allergies,
      user_message: user_message.content
    )
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Ingredient allergy validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Validates metric units
  #
  # @param recipe_data [Hash] Recipe data
  # @return [ValidationResult] Validation result
  def self.validate_metric_units(recipe_data)
    ingredients = recipe_data.dig("content", "ingredients") || []
    shopping_list = recipe_data["shopping_list"] || []

    Tools::MetricUnitValidator.validate(
      ingredients: ingredients,
      shopping_list: shopping_list
    )
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Metric unit validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Validates appliance compatibility
  #
  # @param recipe_data [Hash] Recipe data
  # @param available_appliances [Array<String>] User's available appliances
  # @param unavailable_appliances [Array<String>] User's unavailable appliances
  # @return [ValidationResult] Validation result
  def self.validate_appliance_compatibility(recipe_data, available_appliances, unavailable_appliances)
    instructions = recipe_data.dig("content", "instructions") || []

    Tools::ApplianceCompatibilityChecker.validate(
      instructions: instructions,
      available_appliances: available_appliances,
      unavailable_appliances: unavailable_appliances
    )
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Appliance compatibility validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Validates recipe completeness
  #
  # @param recipe_data [Hash] Recipe data
  # @return [ValidationResult] Validation result
  def self.validate_recipe_completeness(recipe_data)
    Tools::RecipeCompletenessChecker.validate(recipe_data: recipe_data)
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Recipe completeness validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Validates preference compliance
  #
  # @param recipe_data [Hash] Recipe data
  # @param user [User] Current user
  # @return [ValidationResult] Validation result
  def self.validate_preference_compliance(recipe_data, user)
    Tools::PreferenceComplianceChecker.validate(
      recipe_data: recipe_data,
      user_preferences: user.preferences,
      user_age: user.age,
      user_weight: user.weight,
      user_gender: user.gender
    )
  rescue StandardError => e
    Rails.logger.error("RecipeValidator: Preference compliance validation failed: #{e.message}")
    Tools::BaseTool.validation_result(valid: true, violations: [])
  end

  # Aggregates validation results from all validators
  #
  # @param results [Hash] Hash of validation results keyed by validator name
  # @return [Hash] Aggregated results with all violations and fix instructions
  def self.aggregate_results(results)
    all_violations = []
    all_fix_instructions = []

    results.each_value do |result|
      next unless result

      all_violations.concat(result.violations) if result.respond_to?(:violations) && result.violations
      all_fix_instructions << result.fix_instructions if result.respond_to?(:fix_instructions) && result.fix_instructions.present?
    end

    {
      valid: all_violations.empty?,
      violations: all_violations,
      fix_instructions: all_fix_instructions
    }
  end

end

