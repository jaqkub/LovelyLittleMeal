require "ruby_llm/schema"

# Schema for ConversationContextAnalyzer tool output
# Ensures structured context analysis results
# Moved to separate file to prevent redefinition issues in development mode
module Tools
  unless defined?(Tools::ConversationContextSchema)
    class ConversationContextSchema < RubyLLM::Schema
      boolean :is_first_message,
              description: "True if this is the first message in the conversation (no previous messages)"

      array :previous_topics,
            of: :string,
            description: "Array of topics discussed in previous messages (e.g., ['recipe creation', 'ingredient modification'])"

      array :recent_changes,
            of: :string,
            description: "Array of recent changes made to the recipe (e.g., ['added salt', 'removed dairy'])"

      string :conversation_tone,
             description: "The tone of the conversation: 'friendly', 'formal', 'casual', 'technical', or 'mixed'"

      boolean :greeting_needed,
              description: "True if a greeting should be included in the response (only true for first messages)"
    end
  end
end
