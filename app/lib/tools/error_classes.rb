# Tool-specific error classes for the agentic workflow system
# These errors are used by tools to communicate validation failures and other issues

module Tools
  # Base error class for all tool errors
  class ToolError < StandardError
    attr_reader :tool_name, :details

    def initialize(tool_name, message, details = {})
      super(message)
      @tool_name = tool_name
      @details = details
    end
  end

  # Raised when a tool validation fails
  # Contains structured violation information for fixing
  class ValidationError < ToolError
    attr_reader :violations

    def initialize(tool_name, message, violations = [])
      super(tool_name, message, { violations: violations })
      @violations = violations
    end
  end

  # Raised when a tool cannot execute due to invalid input
  class InvalidInputError < ToolError
  end

  # Raised when a tool execution fails (network errors, etc.)
  class ExecutionError < ToolError
  end
end

