require "json"
require_relative "base_tool"
require_relative "error_classes"

# Validates that recipes align with user preferences
# Checks recipe against user's dietary preferences, cooking preferences, and other custom preferences
# Uses GPT-4.1-nano for fast preference compliance analysis
#
# This tool ensures recipes match user preferences before being returned
#
# Validation checks:
# - Recipe aligns with dietary preferences (if specified)
# - Recipe aligns with cooking preferences (if specified)
# - Recipe aligns with any custom preferences (if specified)
# - Recipe respects user's physical information (age, weight, gender) if relevant
module Tools
  class PreferenceComplianceChecker
    include BaseTool

    # Validates recipe compliance with user preferences
    #
    # @param recipe_data [Hash] The recipe data to validate (from LLM response)
    # @param user_preferences [String, nil] User's preferences text (free-form)
    # @param user_age [Integer, nil] User's age
    # @param user_weight [Integer, nil] User's weight in kg
    # @param user_gender [Boolean, nil] User's gender (true = male, false = female)
    # @return [ValidationResult] Validation result with violations and fix instructions
    def self.validate(recipe_data:, user_preferences: nil, user_age: nil, user_weight: nil, user_gender: nil)
      # If no preferences specified, recipe is automatically compliant
      return BaseTool.validation_result(valid: true, violations: []) if user_preferences.blank? && user_age.nil? && user_weight.nil? && user_gender.nil?

      # Extract recipe information for analysis
      recipe_info = extract_recipe_info(recipe_data)

      # Use LLM to check compliance
      compliance_issues = check_compliance(recipe_info, user_preferences, user_age, user_weight, user_gender)

      # Generate fix instructions
      fix_instructions = generate_fix_instructions(compliance_issues, user_preferences)

      BaseTool.validation_result(
        valid: compliance_issues.empty?,
        violations: compliance_issues,
        fix_instructions: fix_instructions
      )
    rescue StandardError => e
      Rails.logger.error("PreferenceComplianceChecker: Error during validation: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      # Return valid result if validation fails (preferences are not critical)
      # We don't want to block recipe generation if preference checking fails
      BaseTool.validation_result(valid: true, violations: [])
    end

    private

    # Extracts recipe information for analysis
    #
    # @param recipe_data [Hash] Recipe data
    # @return [String] Formatted recipe information
    def self.extract_recipe_info(recipe_data)
      parts = []

      parts << "Title: #{recipe_data['title'] || recipe_data[:title] || 'N/A'}"
      parts << "Description: #{recipe_data['description'] || recipe_data[:description] || 'N/A'}"

      content = recipe_data["content"] || recipe_data[:content] || {}
      if content.is_a?(Hash)
        ingredients = content["ingredients"] || content[:ingredients] || []
        instructions = content["instructions"] || content[:instructions] || []

        parts << "Ingredients: #{ingredients.join(', ')}" if ingredients.any?
        parts << "Instructions: #{instructions.join(' | ')}" if instructions.any?
      end

      parts.join("\n")
    end

    # Checks recipe compliance with user preferences using LLM
    #
    # @param recipe_info [String] Formatted recipe information
    # @param user_preferences [String, nil] User preferences
    # @param user_age [Integer, nil] User age
    # @param user_weight [Integer, nil] User weight
    # @param user_gender [Boolean, nil] User gender
    # @return [Array<Hash>] Array of violation hashes
    def self.check_compliance(recipe_info, user_preferences, user_age, user_weight, user_gender)
      # Build compliance check prompt
      compliance_prompt = build_compliance_prompt(recipe_info, user_preferences, user_age, user_weight, user_gender)

      # Use GPT-4.1-nano for fast compliance analysis
      chat = RubyLLM.chat(model: "gpt-4.1-nano")
                     .with_instructions(compliance_instructions)

      # Ask for compliance analysis
      response = chat.ask(compliance_prompt).content

      # Parse response
      parse_compliance_response(response)
    rescue StandardError => e
      Rails.logger.error("PreferenceComplianceChecker: Error checking compliance: #{e.message}")
      # Return empty violations if LLM fails (preferences are not critical)
      []
    end

    # Builds compliance check instructions for LLM
    #
    # @return [String] Compliance instructions
    def self.compliance_instructions
      <<~INSTRUCTIONS
        You are analyzing a recipe to check if it aligns with user preferences and requirements.

        Your task:
        1. Read the user's preferences carefully
        2. Read the recipe information
        3. Identify any violations where the recipe does NOT align with user preferences
        4. Be specific about what violates the preferences
        5. Return a JSON object with:
           - "violations": Array of { "type": "preference_violation", "message": "description", "field": "field_name", "preference": "which preference was violated" }

        Important:
        - Only report actual violations (recipe doesn't match preferences)
        - Be specific about what violates the preference
        - If recipe aligns with preferences, return empty violations array
        - Consider dietary preferences, cooking methods, ingredient preferences, etc.
        - Physical information (age, weight, gender) should only be considered if relevant to the recipe

        Return ONLY valid JSON, no other text.
      INSTRUCTIONS
    end

    # Builds compliance check prompt
    #
    # @param recipe_info [String] Recipe information
    # @param user_preferences [String, nil] User preferences
    # @param user_age [Integer, nil] User age
    # @param user_weight [Integer, nil] User weight
    # @param user_gender [Boolean, nil] User gender
    # @return [String] Compliance prompt
    def self.build_compliance_prompt(recipe_info, user_preferences, user_age, user_weight, user_gender)
      parts = []
      parts << "Analyze the following recipe for compliance with user preferences:"
      parts << ""
      parts << "Recipe:"
      parts << recipe_info
      parts << ""

      if user_preferences.present?
        parts << "User Preferences:"
        parts << user_preferences
        parts << ""
      end

      if user_age || user_weight || !user_gender.nil?
        parts << "User Physical Information:"
        parts << "Age: #{user_age}" if user_age
        parts << "Weight: #{user_weight} kg" if user_weight
        parts << "Gender: #{user_gender ? 'Male' : 'Female'}" unless user_gender.nil?
        parts << ""
      end

      parts << "Return a JSON object with:"
      parts << "{"
      parts << '  "violations": ['
      parts << '    {'
      parts << '      "type": "preference_violation",'
      parts << '      "message": "description of violation",'
      parts << '      "field": "field_name",'
      parts << '      "preference": "which preference was violated"'
      parts << '    }'
      parts << '  ]'
      parts << "}"
      parts << ""
      parts << "If the recipe aligns with all preferences, return empty violations array."

      parts.join("\n")
    end

    # Parses LLM response for compliance analysis
    #
    # @param response [String, Hash] LLM response
    # @return [Array<Hash>] Array of violation hashes
    def self.parse_compliance_response(response)
      # Handle different response formats
      result = case response
               when String
                 begin
                   JSON.parse(response)
                 rescue JSON::ParserError
                   # Try to extract JSON from text
                   json_match = response.match(/\{[\s\S]*\}/)
                   json_match ? JSON.parse(json_match[0]) : {}
                 end
               when Hash
                 response
               else
                 {}
               end

      violations = []

      # Parse violations
      violations_list = Array(result["violations"] || result[:violations] || [])
      violations_list.each do |violation|
        violations << BaseTool.violation(
          type: :preference_violation,
          message: violation["message"] || violation[:message] || "Recipe does not align with user preferences",
          field: (violation["field"] || violation[:field] || :general).to_sym,
          fix_instruction: "Adjust recipe to align with user preference: #{violation['preference'] || violation[:preference] || 'user preferences'}"
        )
      end

      violations
    end

    # Generates fix instructions for preference violations
    #
    # @param violations [Array<Hash>] Violation hashes
    # @param user_preferences [String, nil] User preferences
    # @return [String] Fix instructions
    def self.generate_fix_instructions(violations, user_preferences)
      return "Recipe aligns with user preferences." if violations.empty?

      instructions = []
      instructions << "CRITICAL: The recipe does not align with user preferences."
      instructions << ""
      instructions << "User Preferences:"
      instructions << (user_preferences || "Not specified")
      instructions << ""
      instructions << "Preference Violations:"
      violations.each do |violation|
        instructions << "  - #{violation[:message]}"
      end
      instructions << ""
      instructions << "Fix instructions:"
      instructions << "1. Review the user preferences carefully"
      instructions << "2. Adjust the recipe to align with all user preferences"
      instructions << "3. Ensure the recipe respects dietary preferences, cooking methods, and ingredient preferences"
      instructions << "4. Verify the recipe matches the user's requirements"

      instructions.join("\n")
    end
  end
end

