import { Controller } from "@hotwired/stimulus"

// Auto-scrolls chat messages container to bottom when new messages are added
// Hides empty message when user sends first message
// Uses MutationObserver to detect when new content is appended via Turbo Stream
export default class extends Controller {
  static targets = ["messages", "form", "input", "submit"]

  connect() {
    // Scroll to bottom on initial load
    this.scrollToBottom()
    
    // Set up input validation for send button
    this.setupInputValidation()
    
    // Set up MutationObserver to watch for new child elements (new messages)
    // Only auto-scroll if user is already at the bottom (hasn't scrolled up)
    this.messagesObserver = new MutationObserver(() => {
      // Only scroll to bottom if user is already near the bottom
      // This allows users to scroll up to read older messages without interruption
      if (this.isNearBottom()) {
        requestAnimationFrame(() => {
          this.scrollToBottom()
        })
      }
    })
    
    // Observe changes to child elements (when messages are added)
    if (this.hasMessagesTarget) {
      this.messagesObserver.observe(this.messagesTarget, {
        childList: true,
        subtree: true
      })
    }
    
    // Set up observer for form changes (when form is replaced via turbo_stream)
    if (this.hasFormTarget) {
      this.formObserver = new MutationObserver(() => {
        // Re-setup input validation when form is replaced
        requestAnimationFrame(() => {
          this.setupInputValidation()
        })
      })
      
      this.formObserver.observe(this.formTarget, {
        childList: true,
        subtree: true
      })
    }
    
    // Handle form submission - show optimistic updates immediately
    this.element.addEventListener("turbo:submit-start", (event) => {
      this.handleFormSubmit(event)
    })
  }

  disconnect() {
    // Clean up observers when controller is disconnected
    if (this.messagesObserver) {
      this.messagesObserver.disconnect()
    }
    if (this.formObserver) {
      this.formObserver.disconnect()
    }
  }

  setupInputValidation() {
    // Enable/disable send button based on input content
    // Stimulus automatically reconnects targets when form is replaced via turbo_stream
    if (this.hasInputTarget && this.hasSubmitTarget) {
      // Update button state immediately
      this.updateSubmitButton()
      
      // Add event listener for input changes
      // Using a bound function stored on the controller to allow cleanup if needed
      if (!this.boundUpdateSubmitButton) {
        this.boundUpdateSubmitButton = () => this.updateSubmitButton()
      }
      this.inputTarget.addEventListener("input", this.boundUpdateSubmitButton)
    }
  }

  updateSubmitButton() {
    // Disable submit button if input is empty
    if (this.hasInputTarget && this.hasSubmitTarget) {
      const hasContent = this.inputTarget.value.trim().length > 0
      this.submitTarget.disabled = !hasContent
    }
  }

  handleFormSubmit(event) {
    // Hide empty message immediately
    this.hideEmptyMessage()
    
    // Get form and input values
    const form = event.target.closest('form')
    if (!form || !this.hasMessagesTarget) return
    
    const input = form.querySelector('input[type="text"], input[name="content"]')
    if (!input || !input.value.trim()) return
    
    const userMessageContent = input.value.trim()
    
    // Store the message content to prevent duplicates
    // Mark that we've added optimistic updates for this submission
    this.optimisticUpdateInProgress = true
    
    // Create optimistic user message with a temporary ID that can be replaced
    const tempId = `user-msg-${Date.now()}`
    const userMessageHtml = `
      <div id="optimistic-user-msg" class="d-flex mb-3 message-item justify-content-end" data-optimistic-user-msg="${tempId}">
        <div class="message-bubble user-message">
          ${this.escapeHtml(userMessageContent).replace(/\n/g, '<br>')}
        </div>
      </div>
    `
    
    // Create loading bubble
    const loadingHtml = `
      <div id="loading" class="d-flex mb-3 justify-content-start">
        <div class="message-bubble assistant-message d-flex align-items-center gap-2">
          <div class="spinner-border spinner-border-sm text-muted" role="status" style="width: 1rem; height: 1rem;">
            <span class="visually-hidden">Loading...</span>
          </div>
          <span class="text-muted mb-0">Thinking...</span>
        </div>
      </div>
    `
    
    // Append both messages immediately
    this.messagesTarget.insertAdjacentHTML('beforeend', userMessageHtml + loadingHtml)
    
    // Scroll to bottom
    requestAnimationFrame(() => {
      this.scrollToBottom()
    })
    
    // Clear input immediately for better UX
    input.value = ''
    this.updateSubmitButton()
    
    // Reset flag after a delay (server response should come before this)
    setTimeout(() => {
      this.optimisticUpdateInProgress = false
    }, 10000)
  }
  
  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  hideEmptyMessage() {
    // Hide empty message immediately when form is submitted
    const emptyMessage = document.getElementById('empty-chat-message')
    if (emptyMessage) {
      emptyMessage.style.opacity = '0'
      emptyMessage.style.transition = 'opacity 0.2s ease-out'
      setTimeout(() => {
        if (emptyMessage.parentNode) {
          emptyMessage.style.display = 'none'
        }
      }, 200)
    }
  }

  isNearBottom() {
    // Check if user is near the bottom of the scroll container (within 100px)
    // This allows auto-scroll when at bottom, but prevents interrupting manual scrolling
    if (!this.hasMessagesTarget) return true
    
    const container = this.messagesTarget
    const threshold = 100 // pixels from bottom
    const distanceFromBottom = container.scrollHeight - container.scrollTop - container.clientHeight
    
    return distanceFromBottom < threshold
  }

  scrollToBottom() {
    // Scroll to the bottom of the messages container to show newest messages
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }
}

