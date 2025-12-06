require "ruby_llm/schema"

# Schema for IntentClassifier tool output
# Ensures structured classification results with all required fields
# Moved to separate file to prevent redefinition issues in development mode
module Tools
  unless defined?(Tools::IntentClassificationSchema)
    class IntentClassificationSchema < RubyLLM::Schema
      string :intent,
             description: "The classified intent type. Must be one of: first_message_link, first_message_free_text, first_message_complete_recipe, first_message_query, question, modification, clarification"

      number :confidence,
             description: "Confidence score from 0.0 to 1.0 indicating how certain the classification is"

      string :detected_url,
             description: "If intent is first_message_link, this should contain the detected URL. Otherwise null or empty string."

      string :reasoning,
             description: "Brief explanation of why this intent was chosen (1-2 sentences)"
    end
  end
end
