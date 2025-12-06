require "json"
require_relative "base_tool"
require_relative "error_classes"

# Validates that recipes use only available appliances
# Checks instructions against user's available and unavailable appliances
# Uses GPT-4.1-nano for fast appliance detection in instructions
#
# This tool addresses the critical requirement that recipes must be executable
# with only the user's available equipment
#
# Validation checks:
# - Instructions must not mention unavailable appliances
# - Instructions should use only available appliances
# - Provides specific fix instructions for violations
module Tools
  class ApplianceCompatibilityChecker
    include BaseTool

    # Validates appliance compatibility in recipe instructions
    #
    # @param instructions [Array<String>] The recipe instructions array to validate
    # @param available_appliances [Array<String>] List of user's available appliances (e.g., ["stove", "oven"])
    # @param unavailable_appliances [Array<String>] List of user's unavailable appliances (e.g., ["microwave", "blender"])
    # @return [ValidationResult] Validation result with violations and fix instructions
    def self.validate(instructions:, available_appliances:, unavailable_appliances:)
      violations = []
      instructions = Array(instructions) # Ensure it's an array

      # If no unavailable appliances, recipe is automatically compatible
      return BaseTool.validation_result(valid: true, violations: []) if unavailable_appliances.empty?

      # If no instructions, can't validate
      return BaseTool.validation_result(
        valid: false,
        violations: [BaseTool.violation(
          type: :no_instructions,
          message: "Recipe has no instructions to validate",
          field: :instructions,
          fix_instruction: "Add instructions to the recipe"
        )],
        fix_instructions: "Recipe must have instructions"
      ) if instructions.empty?

      # Use LLM to detect appliance usage in instructions
      # This is more reliable than regex matching for detecting appliance mentions
      appliance_usage = detect_appliance_usage(instructions, available_appliances, unavailable_appliances)

      # Check for violations
      appliance_usage[:unavailable_used].each do |appliance_info|
        violations << BaseTool.violation(
          type: :unavailable_appliance_used,
          message: "Unavailable appliance '#{appliance_info[:appliance]}' is used in instruction step #{appliance_info[:step_number]}",
          field: :instructions,
          fix_instruction: "Replace or remove the use of '#{appliance_info[:appliance]}' in step #{appliance_info[:step_number]} with an available appliance or alternative method"
        )
      end

      # Generate fix instructions
      fix_instructions = generate_fix_instructions(available_appliances, unavailable_appliances, appliance_usage[:unavailable_used])

      BaseTool.validation_result(
        valid: violations.empty?,
        violations: violations,
        fix_instructions: fix_instructions
      )
    end

    private

    # Detects which appliances are used in instructions using LLM
    #
    # @param instructions [Array<String>] Recipe instructions
    # @param available_appliances [Array<String>] Available appliances
    # @param unavailable_appliances [Array<String>] Unavailable appliances
    # @return [Hash] Hash with :available_used and :unavailable_used arrays
    def self.detect_appliance_usage(instructions, available_appliances, unavailable_appliances)
      # Build detection prompt
      detection_prompt = build_detection_prompt(instructions, available_appliances, unavailable_appliances)

      # Use GPT-4.1-nano for fast appliance detection
      chat = RubyLLM.chat(model: "gpt-4.1-nano")
                     .with_instructions(detection_instructions)

      # Ask for appliance detection
      response = chat.ask(detection_prompt).content

      # Parse response (expecting JSON-like structure)
      parse_appliance_detection(response, instructions.length)
    rescue StandardError => e
      Rails.logger.error("ApplianceCompatibilityChecker: Error detecting appliances: #{e.message}")
      # Fallback to basic pattern matching if LLM fails
      fallback_detection(instructions, available_appliances, unavailable_appliances)
    end

    # Builds detection instructions for LLM
    #
    # @return [String] Detection instructions
    def self.detection_instructions
      <<~INSTRUCTIONS
        You are analyzing recipe instructions to detect which cooking appliances are mentioned.

        Your task:
        1. Read each instruction step carefully
        2. Identify which appliances are mentioned or required in each step
        3. Match them against the provided lists of available and unavailable appliances
        4. Return a JSON object with:
           - "available_used": Array of { "appliance": "name", "step": number } objects
           - "unavailable_used": Array of { "appliance": "name", "step": number } objects

        Be thorough - check for:
        - Direct mentions (e.g., "use the oven", "microwave for 2 minutes")
        - Implied usage (e.g., "bake at 350°F" implies oven)
        - Alternative names (e.g., "stovetop" = "stove", "cooktop" = "stove")

        Return ONLY valid JSON, no other text.
      INSTRUCTIONS
    end

    # Builds detection prompt
    #
    # @param instructions [Array<String>] Recipe instructions
    # @param available_appliances [Array<String>] Available appliances
    # @param unavailable_appliances [Array<String>] Unavailable appliances
    # @return [String] Detection prompt
    def self.build_detection_prompt(instructions, available_appliances, unavailable_appliances)
      <<~PROMPT
        Analyze the following recipe instructions and detect which appliances are used.

        Available Appliances: #{available_appliances.join(", ")}
        Unavailable Appliances: #{unavailable_appliances.join(", ")}

        Instructions:
        #{instructions.each_with_index.map { |inst, idx| "#{idx + 1}. #{inst}" }.join("\n")}

        Return a JSON object with:
        {
          "available_used": [{"appliance": "stove", "step": 1}, ...],
          "unavailable_used": [{"appliance": "oven", "step": 3}, ...]
        }

        Step numbers are 1-based (first instruction is step 1).
      PROMPT
    end

    # Parses LLM response for appliance detection
    #
    # @param response [String, Hash] LLM response
    # @param instruction_count [Integer] Number of instructions
    # @return [Hash] Parsed appliance usage
    def self.parse_appliance_detection(response, instruction_count)
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

      # Normalize structure
      available_used = Array(result["available_used"] || result[:available_used] || [])
      unavailable_used = Array(result["unavailable_used"] || result[:unavailable_used] || [])

      # Convert step numbers to 0-based indices and validate
      {
        available_used: normalize_appliance_list(available_used, instruction_count),
        unavailable_used: normalize_appliance_list(unavailable_used, instruction_count)
      }
    end

    # Normalizes appliance list with step numbers
    #
    # @param appliance_list [Array] List of appliance objects
    # @param instruction_count [Integer] Number of instructions
    # @return [Array] Normalized list with step_index and step_number
    def self.normalize_appliance_list(appliance_list, instruction_count)
      appliance_list.map do |item|
        step = item["step"] || item[:step] || item["step_number"] || item[:step_number] || 1
        step_number = step.to_i
        step_index = step_number - 1 # Convert to 0-based

        # Validate step number
        next nil if step_index < 0 || step_index >= instruction_count

        {
          appliance: (item["appliance"] || item[:appliance] || "").to_s,
          step_number: step_number,
          step_index: step_index
        }
      end.compact
    end

    # Fallback detection using pattern matching
    #
    # @param instructions [Array<String>] Recipe instructions
    # @param available_appliances [Array<String>] Available appliances
    # @param unavailable_appliances [Array<String>] Unavailable appliances
    # @return [Hash] Detected appliance usage
    def self.fallback_detection(instructions, available_appliances, unavailable_appliances)
      available_used = []
      unavailable_used = []

      instructions.each_with_index do |instruction, index|
        instruction_lower = instruction.downcase

        # Check for unavailable appliances
        unavailable_appliances.each do |appliance|
          appliance_lower = appliance.downcase
          # Check for appliance name or common variations
          if instruction_lower.include?(appliance_lower) ||
             instruction_lower.match?(/\b#{appliance_lower.gsub("_", "[-_ ]?")}\b/i)
            unavailable_used << {
              appliance: appliance,
              step_number: index + 1,
              step_index: index
            }
          end
        end

        # Check for available appliances
        available_appliances.each do |appliance|
          appliance_lower = appliance.downcase
          if instruction_lower.include?(appliance_lower) ||
             instruction_lower.match?(/\b#{appliance_lower.gsub("_", "[-_ ]?")}\b/i)
            available_used << {
              appliance: appliance,
              step_number: index + 1,
              step_index: index
            }
          end
        end
      end

      {
        available_used: available_used,
        unavailable_used: unavailable_used
      }
    end

    # Generates fix instructions for violations
    #
    # @param available_appliances [Array<String>] Available appliances
    # @param unavailable_appliances [Array<String>] Unavailable appliances
    # @param violations [Array<Hash>] Violation details
    # @return [String] Fix instructions
    def self.generate_fix_instructions(available_appliances, unavailable_appliances, violations)
      return "No appliance violations found." if violations.empty?

      instructions = []
      instructions << "CRITICAL: The recipe uses unavailable appliances that must be replaced."
      instructions << ""
      instructions << "Unavailable appliances used:"
      violations.each do |violation|
        instructions << "  - #{violation[:appliance]} in step #{violation[:step_number]}"
      end
      instructions << ""
      instructions << "Available appliances you can use: #{available_appliances.join(", ")}"
      instructions << ""
      instructions << "Fix instructions:"
      instructions << "1. Replace or remove the use of unavailable appliances in the mentioned steps"
      instructions << "2. Use only appliances from the available list: #{available_appliances.join(", ")}"
      instructions << "3. If an unavailable appliance is required, find an alternative cooking method using available appliances"
      instructions << "4. Ensure the recipe can be fully executed with only available equipment"

      instructions.join("\n")
    end
  end
end

