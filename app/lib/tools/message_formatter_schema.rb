require "ruby_llm/schema"

# Schema for MessageFormatter tool output
# Ensures structured message formatting results
# Moved to separate file to prevent redefinition issues in development mode
module Tools
  unless defined?(Tools::MessageFormatterSchema)
    class MessageFormatterSchema < RubyLLM::Schema
      string :message,
             description: "The formatted response message to the user. Should be concise, friendly, and contextually appropriate. No greeting on follow-up messages."

      string :tone,
             description: "The tone of the message: 'friendly', 'formal', 'casual', 'technical', or 'mixed'"

      boolean :includes_greeting,
              description: "True if the message includes a greeting (should only be true for first messages)"

      string :change_summary,
              description: "Brief summary of what was changed in the recipe (e.g., 'Added peanuts with warning', 'Modified cooking time')"
    end
  end
end

