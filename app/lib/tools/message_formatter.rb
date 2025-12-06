require_relative "message_formatter_schema"

# Tool for formatting response messages to users
# Ensures messages are properly structured, contextually appropriate, and avoid repetitive greetings
#
# This tool addresses issues where:
# - Messages include greetings on follow-up messages
# - Messages don't reflect actual changes made
# - Messages are too verbose or unclear
#
# Uses GPT-4.1-nano for fast, cost-effective message formatting
module Tools
  class MessageFormatter
    # Formats a response message based on context and changes
    #
    # @param recipe_data [Hash] The generated/modified recipe data
    # @param conversation_context [Hash] Context from ConversationContextAnalyzer (greeting_needed, previous_topics, etc.)
    # @param intent [String] User intent from IntentClassifier
    # @param changes_made [Hash] Summary of changes made (e.g., { allergens_added: true, ingredients_modified: true })
    # @return [Hash] Formatted message with tone and metadata
    def self.format(recipe_data:, conversation_context: {}, intent: nil, changes_made: {})
      # Build formatting instructions
      formatting_instructions = build_formatting_instructions(conversation_context, intent, changes_made)

      # Build the prompt with context
      formatting_prompt = build_formatting_prompt(recipe_data, conversation_context, intent, changes_made)

      # Use GPT-4.1-nano for fast message formatting
      # Reference: https://rubyllm.com/tools/
      chat = RubyLLM.chat(model: "gpt-4.1-nano")
                     .with_instructions(formatting_instructions)
                     .with_schema(MessageFormatterSchema)

      # Ask for formatted message
      response = chat.ask(formatting_prompt).content

      # Parse and return structured result
      parse_formatted_message(response)
    end

    private

    # Builds formatting instructions for the LLM
    #
    # @param conversation_context [Hash] Conversation context
    # @param intent [String] User intent
    # @param changes_made [Hash] Changes made to recipe
    # @return [String] Formatting instructions
    def self.build_formatting_instructions(conversation_context, intent, changes_made)
      greeting_needed = conversation_context.fetch(:greeting_needed, false)
      is_first_message = conversation_context.fetch(:is_first_message, false)

      <<~INSTRUCTIONS
        You are formatting a response message to a user about their recipe.

        CRITICAL RULES:
        1. **Greeting Rules**:
           - Include a greeting ONLY if greeting_needed is true (typically only for first messages)
           - For follow-up messages, get straight to the point - NO greeting
           - If greeting_needed is false, start directly with the message content

        2. **Message Content**:
           - Be concise and friendly
           - Mention what was actually changed or created
           - If allergens were added with warnings, mention this clearly
           - If recipe was modified, summarize the key changes
           - Keep it brief (1-2 sentences typically)

        3. **Tone**:
           - Match the conversation tone if provided
           - Default to friendly and helpful
           - Be professional but warm

        4. **Change Summary**:
           - Provide a brief summary of what changed
           - Be specific but concise
           - Examples: "Added peanuts with allergen warning", "Modified cooking time to 20 minutes", "Created new recipe"

        5. **No Duplication**:
           - Do NOT repeat information unnecessarily
           - Do NOT duplicate phrases like "Proceed with extreme caution" in the message
           - Keep the message clean and focused

        Return a properly formatted message that follows these rules.
      INSTRUCTIONS
    end

    # Builds the formatting prompt with all context
    #
    # @param recipe_data [Hash] Recipe data
    # @param conversation_context [Hash] Conversation context
    # @param intent [String] User intent
    # @param changes_made [Hash] Changes made
    # @return [String] Formatting prompt
    def self.build_formatting_prompt(recipe_data, conversation_context, intent, changes_made)
      recipe_title = recipe_data["title"] || "the recipe"
      greeting_needed = conversation_context.fetch(:greeting_needed, false)
      is_first_message = conversation_context.fetch(:is_first_message, false)
      previous_topics = conversation_context.fetch(:previous_topics, [])
      conversation_tone = conversation_context.fetch(:conversation_tone, "friendly")

      prompt = <<~PROMPT
        Format a response message for the user about their recipe.

        Context:
        - Recipe Title: #{recipe_title}
        - User Intent: #{intent || "unknown"}
        - Is First Message: #{is_first_message}
        - Greeting Needed: #{greeting_needed}
        - Previous Topics: #{previous_topics.join(", ") || "none"}
        - Conversation Tone: #{conversation_tone}

        Changes Made:
        #{format_changes_made(changes_made)}

        Recipe Summary:
        #{recipe_data["description"] || "No description"}

        Instructions:
        #{build_formatting_instructions(conversation_context, intent, changes_made)}

        Format a response message that:
        1. #{greeting_needed ? "Includes a friendly greeting" : "Does NOT include a greeting - get straight to the point"}
        2. Mentions what was actually changed or created
        3. Is concise and friendly
        4. Matches the conversation tone (#{conversation_tone})
      PROMPT

      prompt
    end

    # Formats changes_made hash into readable text
    #
    # @param changes_made [Hash] Changes made to recipe
    # @return [String] Formatted changes text
    def self.format_changes_made(changes_made)
      return "No specific changes tracked" if changes_made.empty?

      changes = []
      changes << "Allergens added with warnings" if changes_made[:allergens_added]
      changes << "Ingredients modified" if changes_made[:ingredients_modified]
      changes << "Instructions modified" if changes_made[:instructions_modified]
      changes << "New recipe created" if changes_made[:new_recipe]
      changes << "Recipe modified" if changes_made[:recipe_modified]

      changes.any? ? changes.join(", ") : "Recipe updated"
    end

    # Parses the formatted message response
    #
    # @param response [Hash] LLM response
    # @return [Hash] Parsed message with metadata
    def self.parse_formatted_message(response)
      {
        message: response["message"] || response[:message] || "Recipe updated successfully.",
        tone: response["tone"] || response[:tone] || "friendly",
        includes_greeting: response["includes_greeting"] || response[:includes_greeting] || false,
        change_summary: response["change_summary"] || response[:change_summary] || "Recipe updated"
      }
    end
  end
end

